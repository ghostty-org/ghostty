import AppKit
import SwiftUI

enum QuickInputHistoryLayout {
    static func rowHeight(_ entry: QuickInputHistoryEntry) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1
        let lineHeight = ceil(font.ascender - font.descender + font.leading) + 1
        let text = NSAttributedString(string: String(entry.text.prefix(400)), attributes: [
            .font: font, .paragraphStyle: paragraph,
        ])
        let bounds = text.boundingRect(with: NSSize(width: 368, height: CGFloat.greatestFiniteMagnitude),
                                      options: [.usesLineFragmentOrigin, .usesFontLeading])
        return 30 + min(max(ceil(bounds.height), lineHeight), lineHeight * 3)
    }

    static func listHeight(_ entries: [QuickInputHistoryEntry]) -> CGFloat {
        guard !entries.isEmpty else { return 96 }
        var height: CGFloat = 0
        for entry in entries {
            height += rowHeight(entry)
            if height >= 480 { return 480 }
        }
        return max(height, 40)
    }

}

struct QuickInputHistoryView: View {
    @ObservedObject var model: AgentQuickInputModel
    @ObservedObject var store: QuickInputHistoryStore
    @ObservedObject var settings: OhMyGhosttySettings
    @ObservedObject var presentation: QuickInputHistoryPresentation
    let onSelect: (String) -> Void

    init(model: AgentQuickInputModel, store: QuickInputHistoryStore,
         settings: OhMyGhosttySettings, onSelect: @escaping (String) -> Void) {
        self.model = model
        self.store = store
        self.settings = settings
        self.presentation = model.historyPresentation
        self.onSelect = onSelect
    }

    private var entries: [QuickInputHistoryEntry] {
        store.visibleEntries(paneID: model.targetSurfaceID, tabID: model.historyTabID,
                             scope: settings.quickInputHistoryScope,
                             query: presentation.isSearching ? presentation.query : "")
    }

    var body: some View {
        let matches = entries
        QuickInputHistoryNativeView(model: model, store: store, settings: settings,
                                    presentation: presentation, entries: matches, onSelect: onSelect)
            .frame(width: 400, height: 48 + QuickInputHistoryLayout.listHeight(matches) + 38
                   + (presentation.isSearching ? 42 : 0) + (store.storageError != nil ? 26 : 0))
            .onAppear {
                store.pruneExpired()
                presentation.reconcile(entries: entries)
                presentation.requestFocus()
            }
            .onChange(of: matches.map(\.id)) { _ in presentation.reconcile(entries: entries) }
    }
}

struct QuickInputHistoryNativeView: NSViewControllerRepresentable {
    let model: AgentQuickInputModel
    let store: QuickInputHistoryStore
    let settings: OhMyGhosttySettings
    let presentation: QuickInputHistoryPresentation
    let entries: [QuickInputHistoryEntry]
    let onSelect: (String) -> Void

    func makeNSViewController(context: Context) -> QuickInputHistoryController {
        QuickInputHistoryController()
    }

    func updateNSViewController(_ controller: QuickInputHistoryController, context: Context) {
        controller.update(self)
    }
}

/// The search input stays mounted even at zero height. AppKit owns list reuse,
/// scrolling and pointer hit testing; the existing presentation owns selection.
final class QuickInputHistoryController: NSViewController, NSTableViewDataSource,
    NSTableViewDelegate, NSTextViewDelegate {
    private let root = QuickInputHistoryContainer()
    private let titleLabel = NSTextField(labelWithString: "")
    private let scope = NSTextField(labelWithString: "")
    private let toggle = NSButton()
    private let clear = NSButton()
    private let searchContainer = NSView()
    private let editor = QuickInputHistorySearchTextView()
    private let scroll = NSScrollView()
    private let table = QuickInputHistoryTable()
    private let empty = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private let error = NSTextField(labelWithString: "")
    private var snapshot: QuickInputHistoryNativeView?
    private var entries: [QuickInputHistoryEntry] = []
    private var handledFocusID = -1
    private var keyboardRevision = -1
    private var rowHeights: [UUID: CGFloat] = [:]
    private let dateFormatter = DateFormatter()
    private var languageCode: String?

    override func loadView() {
        view = root
        root.onLayout = { [weak self] in self?.layoutContent() }
        [titleLabel, scope, toggle, searchContainer, scroll, empty, hint, error].forEach(root.addSubview)
        titleLabel.font = .boldSystemFont(ofSize: 13)
        [scope, hint, error].forEach { $0.font = .systemFont(ofSize: 11); $0.textColor = .secondaryLabelColor }
        error.textColor = .systemOrange
        empty.font = .systemFont(ofSize: 13)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        toggle.isBordered = false
        toggle.target = self
        toggle.action = #selector(toggleSearch)
        clear.isBordered = false
        clear.target = self
        clear.action = #selector(clearSearch)
        clear.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        searchContainer.wantsLayer = true
        searchContainer.layer?.masksToBounds = true
        searchContainer.layer?.cornerRadius = 7
        searchContainer.addSubview(editor)
        searchContainer.addSubview(clear)
        editor.delegate = self
        editor.isRichText = false
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 13)
        editor.textColor = .labelColor
        editor.textContainerInset = NSSize(width: 0, height: 7)
        editor.textContainer?.lineFragmentPadding = 0
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.textContainer?.heightTracksTextView = false
        editor.textContainer?.containerSize.height = .greatestFiniteMagnitude
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.onHover = { [weak self] row in
            guard let self, self.entries.indices.contains(row) else { return }
            self.snapshot?.presentation.hover(self.entries[row].id)
            self.syncSelection(scroll: false)
        }
        table.onChoose = { [weak self] row in
            guard let self, self.entries.indices.contains(row) else { return }
            self.snapshot?.presentation.select(self.entries[row].id)
            self.snapshot?.onSelect(self.entries[row].text)
        }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = table
    }

    func update(_ next: QuickInputHistoryNativeView) {
        _ = view
        snapshot = next
        let strings = SettingsStrings(language: next.settings.language)
        let languageChanged = languageCode != strings.languageCode
        languageCode = strings.languageCode
        dateFormatter.locale = Locale(identifier: strings.languageCode)
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short
        titleLabel.stringValue = strings.quickInputHistoryTitle
        scope.stringValue = "\(strings.quickInputHistoryScopeName(next.settings.quickInputHistoryScope))  \(next.entries.count)"
        toggle.image = NSImage(systemSymbolName: next.presentation.isSearching ? "xmark" : "magnifyingglass",
                               accessibilityDescription: nil)
        toggle.toolTip = next.presentation.isSearching ? strings.quickInputHistoryExitSearch : strings.quickInputHistorySearch
        toggle.setAccessibilityLabel(toggle.toolTip)
        clear.setAccessibilityLabel(strings.quickInputHistoryClearSearch)
        clear.isHidden = next.presentation.query.isEmpty
        hint.stringValue = next.settings.quickInputHistoryInsertionMode == .append
            ? strings.quickInputHistoryAppendHint : strings.quickInputHistoryReplaceHint
        error.stringValue = strings.quickInputHistoryStorageError
        error.isHidden = next.store.storageError == nil
        empty.stringValue = next.presentation.isSearching ? strings.quickInputHistoryNoMatches : strings.quickInputHistoryEmpty
        empty.isHidden = !next.entries.isEmpty
        scroll.isHidden = next.entries.isEmpty
        editor.placeholder = strings.quickInputHistorySearch
        editor.isSearching = next.presentation.isSearching
        editor.onBeginSearch = { [weak self] in self?.snapshot?.presentation.beginSearch(clearQuery: true) }
        editor.onMove = { [weak self] delta in
            guard let self, let snapshot = self.snapshot else { return }
            snapshot.presentation.moveSelection(by: delta, entries: self.entries)
            self.syncSelection(scroll: true)
        }
        editor.onSelect = { [weak self] in
            guard let self, let snapshot = self.snapshot,
                  let entry = self.entries.first(where: { $0.id == snapshot.presentation.selectedID }) else { return }
            snapshot.onSelect(entry.text)
        }
        editor.onEscape = { [weak self] in
            guard let snapshot = self?.snapshot else { return }
            if snapshot.presentation.escape() { snapshot.model.requestFocus() }
        }
        editor.onToggle = { [weak self] in
            self?.snapshot?.presentation.close()
            self?.snapshot?.model.requestFocus()
        }
        editor.canRequestFocus = { [weak self] in self?.snapshot?.presentation.isPresented == true }
        if !editor.hasMarkedText(), editor.string != next.presentation.query {
            editor.string = next.presentation.query
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        }
        updateEntries(next.entries)
        if languageChanged, !entries.isEmpty {
            table.reloadData(forRowIndexes: IndexSet(entries.indices), columnIndexes: IndexSet(integer: 0))
        }
        let shouldScroll = keyboardRevision != next.presentation.keyboardSelectionRevision
        keyboardRevision = next.presentation.keyboardSelectionRevision
        syncSelection(scroll: shouldScroll)
        root.needsLayout = true
        if handledFocusID != next.presentation.focusRequestID {
            handledFocusID = next.presentation.focusRequestID
            editor.requestKeyboardFocus()
        }
    }

    private func updateEntries(_ newEntries: [QuickInputHistoryEntry]) {
        guard entries != newEntries else { return }
        let previous = entries
        let difference = newEntries.map(\.id).difference(from: previous.map(\.id))
        entries = newEntries
        table.beginUpdates()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): table.removeRows(at: IndexSet(integer: offset), withAnimation: [])
            case let .insert(offset, _, _): table.insertRows(at: IndexSet(integer: offset), withAnimation: [])
            }
        }
        table.endUpdates()
        let oldByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let nextByID = Dictionary(uniqueKeysWithValues: newEntries.map { ($0.id, $0) })
        let changed = IndexSet(newEntries.indices.filter {
            oldByID[newEntries[$0].id] != newEntries[$0]
        })
        rowHeights = rowHeights.filter { id, _ in
            oldByID[id] == nextByID[id]
        }
        table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
        table.noteHeightOfRows(withIndexesChanged: changed)
    }

    private func syncSelection(scroll shouldScroll: Bool) {
        let row = entries.firstIndex { $0.id == snapshot?.presentation.selectedID }
        table.selectRowIndexes(row.map { IndexSet(integer: $0) } ?? IndexSet(), byExtendingSelection: false)
        if shouldScroll, let row { table.scrollRowToVisible(row) }
    }

    private func layoutContent() {
        guard let snapshot else { return }
        let width = root.bounds.width
        titleLabel.frame = NSRect(x: 14, y: 14, width: 170, height: 22)
        scope.frame = NSRect(x: 184, y: 17, width: max(0, width - 228), height: 18)
        toggle.frame = NSRect(x: width - 38, y: 12, width: 24, height: 24)
        let searchHeight: CGFloat = snapshot.presentation.isSearching ? 42 : 0
        searchContainer.frame = NSRect(x: 14, y: 48, width: width - 28, height: max(0, searchHeight - 10))
        editor.frame = NSRect(x: 9, y: 0, width: width - 68, height: 32)
        clear.frame = NSRect(x: width - 54, y: 4, width: 22, height: 24)
        let listY = 48 + searchHeight
        let listHeight = QuickInputHistoryLayout.listHeight(entries)
        scroll.frame = NSRect(x: 0, y: listY, width: width, height: listHeight)
        empty.frame = NSRect(x: 14, y: listY + 38, width: width - 28, height: 22)
        hint.frame = NSRect(x: 14, y: listY + listHeight + 10, width: width - 28, height: 18)
        error.frame = NSRect(x: 14, y: listY + listHeight + 38, width: width - 28, height: 18)
    }

    @objc private func toggleSearch() {
        guard let presentation = snapshot?.presentation else { return }
        if presentation.isSearching { presentation.endSearch() } else { presentation.beginSearch() }
    }

    @objc private func clearSearch() {
        snapshot?.presentation.query = ""
        snapshot?.presentation.requestFocus()
    }

    func textDidChange(_ notification: Notification) { snapshot?.presentation.query = editor.string }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let entry = entries[row]
        if let cached = rowHeights[entry.id] { return cached }
        let height = QuickInputHistoryLayout.rowHeight(entry)
        rowHeights[entry.id] = height
        return height
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("history-entry")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? QuickInputHistoryCell
            ?? QuickInputHistoryCell()
        cell.identifier = identifier
        let entry = entries[row]
        cell.configure(entry, date: dateFormatter.string(from: entry.sentAt))
        cell.onChoose = { [weak self] in
            self?.snapshot?.presentation.select(entry.id)
            self?.snapshot?.onSelect(entry.text)
        }
        return cell
    }
}

private final class QuickInputHistoryContainer: NSView {
    var onLayout: (() -> Void)?
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); onLayout?() }
}

private final class QuickInputHistoryTable: NSTableView {
    var onHover: ((Int) -> Void)?
    var onChoose: ((Int) -> Void)?
    private var hoverArea: NSTrackingArea?
    // Search remains the sole input client, including when clicking a row.
    override var acceptsFirstResponder: Bool { false }
    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onChoose?(row) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseMoved(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onHover?(row) }
    }
}

private final class QuickInputHistoryCell: NSTableCellView {
    var onChoose: (() -> Void)?
    override func accessibilityPerformPress() -> Bool {
        onChoose?()
        return onChoose != nil
    }
    private let timestamp = NSTextField(labelWithString: "")
    private let preview = NSTextField(wrappingLabelWithString: "")
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        timestamp.font = .systemFont(ofSize: 11)
        timestamp.textColor = .secondaryLabelColor
        preview.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        preview.maximumNumberOfLines = 3
        preview.lineBreakMode = .byTruncatingTail
        addSubview(timestamp)
        addSubview(preview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        timestamp.frame = NSRect(x: 16, y: 6, width: bounds.width - 32, height: 14)
        preview.frame = NSRect(x: 16, y: 23, width: bounds.width - 32, height: max(0, bounds.height - 29))
    }
    func configure(_ entry: QuickInputHistoryEntry, date: String) {
        timestamp.stringValue = date
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1
        paragraph.lineBreakMode = .byTruncatingTail
        preview.attributedStringValue = NSAttributedString(string: String(entry.text.prefix(400)), attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
        toolTip = String(entry.text.prefix(1_000))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(date), \(entry.text)")
    }
}
