import AppKit
import Combine
import SwiftUI

/// Observable state managing active completion suggestions and popup presentation.
@MainActor
public final class CompletionState: ObservableObject {
    static func popupHeight(candidateCount: Int) -> CGFloat {
        min(CGFloat(candidateCount) * 23 + 5, 190)
    }

    static func popupOrigin(caret: CGRect, viewport: CGSize, candidateCount: Int) -> CGPoint {
        let height = popupHeight(candidateCount: candidateCount)
        let below = caret.maxY + 4
        let y = below + height <= viewport.height ? below : caret.minY - height - 4
        return CGPoint(x: max(0, min(caret.minX, viewport.width - 250)),
                       y: max(0, min(y, viewport.height - height)))
    }
    @Published public var isPresented: Bool = false
    @Published public var candidates: [CompletionItem] = []
    @Published public var selectedIndex: Int = 0
    @Published public var prefix: String = ""
    @Published public var prefixRange: NSRange = NSRange(location: 0, length: 0)
    @Published public var presentationPoint: CGPoint = .zero

    public init() {}

    public var currentSelection: CompletionItem? {
        guard isPresented, !candidates.isEmpty, selectedIndex >= 0, selectedIndex < candidates.count else {
            return nil
        }
        return candidates[selectedIndex]
    }

    public func selectNext() {
        guard !candidates.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % candidates.count
    }

    public func selectPrevious() {
        guard !candidates.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + candidates.count) % candidates.count
    }

    public func dismiss() {
        // Selection updates also arrive during SwiftUI reconciliation. Publishing
        // unchanged values here feeds another reconciliation and never settles.
        if isPresented { isPresented = false }
        if !candidates.isEmpty { candidates = [] }
        if selectedIndex != 0 { selectedIndex = 0 }
        if !prefix.isEmpty { prefix = "" }
        if prefixRange != .zero { prefixRange = .zero }
    }

    public func update(
        candidates: [CompletionItem],
        prefix: String,
        prefixRange: NSRange,
        at point: CGPoint
    ) {
        let candidates = candidates.filter { $0.label.lowercased().hasPrefix(prefix.lowercased()) }
        let selected = currentSelection
        self.candidates = candidates
        self.prefix = prefix
        self.prefixRange = prefixRange
        self.presentationPoint = point
        self.selectedIndex = selected.flatMap { candidates.firstIndex(of: $0) } ?? 0
        self.isPresented = !candidates.isEmpty
    }

    public func filter(prefix: String, prefixRange: NSRange, at point: CGPoint) {
        let selected = currentSelection
        self.prefix = prefix
        self.prefixRange = prefixRange
        self.presentationPoint = point
        let lower = prefix.lowercased()
        let matching = candidates.filter { $0.label.lowercased().hasPrefix(lower) }
        self.candidates = matching
        self.selectedIndex = selected.flatMap { matching.firstIndex(of: $0) } ?? 0
        self.isPresented = !matching.isEmpty
    }
}

@MainActor
final class EditorCompletionPresenter: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private weak var scrollView: NSScrollView?
    private let state: CompletionState
    private let commit: (CompletionItem) -> Void
    private let popup = EditorCompletionPopup(frame: .zero)
    private var observation: AnyCancellable?
    private var renderedCandidates: [CompletionItem] = []
    private var renderedSelection = -1
    private var renderedPrefix = ""
    private var refreshPending = false
    private var synchronizingSelection = false

    var isMounted: Bool { scrollView != nil && popup.superview === scrollView }
    var isVisible: Bool { isMounted && !popup.isHiddenOrHasHiddenAncestor }
    var popupFrame: CGRect { popup.frame }
    var rowCount: Int { popup.table.numberOfRows }
    var selectedRow: Int { popup.table.selectedRow }

    init(state: CompletionState, commit: @escaping (CompletionItem) -> Void) {
        self.state = state
        self.commit = commit
        super.init()
        popup.table.delegate = self
        popup.table.dataSource = self
        popup.table.target = self
        popup.table.action = #selector(rowActivated)
        observation = state.objectWillChange.sink { [weak self] _ in
            self?.scheduleRefresh()
        }
    }

    func attach(to scrollView: NSScrollView) {
        guard self.scrollView !== scrollView else { refresh(); return }
        detach()
        self.scrollView = scrollView
        scrollView.addSubview(popup)
        refresh()
    }

    func detach() {
        popup.removeFromSuperview()
        scrollView = nil
    }

    func contains(_ event: NSEvent) -> Bool {
        guard let scrollView, !popup.isHidden, !popup.isHiddenOrHasHiddenAncestor,
              event.window === scrollView.window else { return false }
        return popup.frame.contains(scrollView.convert(event.locationInWindow, from: nil))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { renderedCandidates.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard renderedCandidates.indices.contains(row) else { return nil }
        let item = renderedCandidates[row]
        let identifier = NSUserInterfaceItemIdentifier("EditorCompletionCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? EditorCompletionCell)
            ?? EditorCompletionCell(frame: .zero)
        cell.identifier = identifier
        cell.configure(item, prefix: renderedPrefix, selected: row == renderedSelection)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !synchronizingSelection else { return }
        let row = popup.table.selectedRow
        guard renderedCandidates.indices.contains(row), state.selectedIndex != row else { return }
        state.selectedIndex = row
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        state.candidates.indices.contains(row)
    }

    @objc private func rowActivated() {
        let row = popup.table.clickedRow
        guard renderedCandidates.indices.contains(row) else { return }
        commit(renderedCandidates[row])
    }

    private func refresh() {
        refreshPending = false
        guard let scrollView else { return }
        let nextCandidates = state.candidates
        let candidatesChanged = renderedCandidates != nextCandidates
        let prefixChanged = renderedPrefix != state.prefix
        let previousSelection = renderedSelection
        synchronizingSelection = true
        if candidatesChanged {
            renderedCandidates = nextCandidates
        }
        renderedPrefix = state.prefix
        popup.isHidden = !state.isPresented || nextCandidates.isEmpty
        guard !popup.isHidden else {
            if candidatesChanged { popup.table.reloadData() }
            synchronizingSelection = false
            return
        }
        if candidatesChanged { popup.table.reloadData() }
        let size = CGSize(
            width: min(250, scrollView.bounds.width),
            height: min(CompletionState.popupHeight(candidateCount: state.candidates.count), scrollView.bounds.height)
        )
        let origin = CGPoint(
            x: min(max(state.presentationPoint.x, 0), max(0, scrollView.bounds.width - size.width)),
            y: min(max(state.presentationPoint.y, 0), max(0, scrollView.bounds.height - size.height))
        )
        popup.frame = CGRect(origin: origin, size: size)
        if renderedSelection != state.selectedIndex || candidatesChanged {
            if state.candidates.indices.contains(state.selectedIndex) {
                popup.table.selectRowIndexes(IndexSet(integer: state.selectedIndex), byExtendingSelection: false)
            } else {
                popup.table.deselectAll(nil)
            }
            renderedSelection = state.selectedIndex
        }
        synchronizingSelection = false
        if prefixChanged, !candidatesChanged, popup.table.numberOfRows > 0 {
            let visible = popup.table.rows(in: popup.table.visibleRect)
            let rows = visible.location == NSNotFound ? IndexSet() : IndexSet(integersIn: visible.location..<NSMaxRange(visible))
            if !rows.isEmpty {
                popup.table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
            }
        }
        if !candidatesChanged, previousSelection != renderedSelection {
            let changedRows = [previousSelection, renderedSelection].filter { $0 >= 0 && $0 < nextCandidates.count }
            if !changedRows.isEmpty {
                popup.table.reloadData(forRowIndexes: IndexSet(changedRows), columnIndexes: IndexSet(integer: 0))
            }
        }
        if state.selectedIndex >= 0, state.selectedIndex < state.candidates.count {
            popup.table.scrollRowToVisible(state.selectedIndex)
        }
        scrollView.addSubview(popup, positioned: .above, relativeTo: nil)
    }

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }
}

@MainActor
private final class EditorCompletionPopup: NSView {
    let table = NSTableView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -5)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("completion"))
        column.width = 244
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 23
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .regular
        table.focusRingType = .none
        table.refusesFirstResponder = true

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        // The editor creates this hidden popup at zero size before its first query.
        // Keep inset preferences without forcing the scroll view to negative size.
        let trailing = scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3)
        let bottom = scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        trailing.priority = .defaultHigh
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            trailing,
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            bottom
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class EditorCompletionCell: NSTableCellView {
    private let badge = NSTextField(labelWithString: "")
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for field in [badge, label, detail] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingTail
            addSubview(field)
        }
        badge.alignment = .center
        badge.font = .monospacedSystemFont(ofSize: 9, weight: .bold)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detail.font = .systemFont(ofSize: 9)
        detail.textColor = .secondaryLabelColor
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 4),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ item: CompletionItem, prefix: String, selected: Bool) {
        badge.stringValue = item.kind.symbol
        badge.textColor = NSColor(item.kind.color)
        label.attributedStringValue = Self.highlight(item.label, prefix: prefix, selected: selected)
        detail.stringValue = item.detail ?? ""
        detail.isHidden = item.detail == nil
        layer?.backgroundColor = selected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).cgColor : nil
    }

    private static func highlight(_ value: String, prefix: String, selected: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: value,
            attributes: [.foregroundColor: selected ? NSColor.labelColor : NSColor.labelColor]
        )
        guard !prefix.isEmpty,
              let range = value.range(of: prefix, options: .caseInsensitive) else { return result }
        let nsRange = NSRange(range, in: value)
        result.addAttributes([
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.controlAccentColor
        ], range: nsRange)
        return result
    }
}
