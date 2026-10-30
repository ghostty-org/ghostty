import AppKit
import SwiftUI

struct NativeCommandPalette: NSViewControllerRepresentable {
    let options: [CommandOption]
    let finish: (CommandOption?) -> Void

    func makeNSViewController(context: Context) -> CommandPaletteController {
        let controller = CommandPaletteController()
        controller.update(options: options, finish: finish)
        return controller
    }

    func updateNSViewController(_ controller: CommandPaletteController, context: Context) {
        controller.update(options: options, finish: finish)
    }
}

final class CommandPaletteController: NSViewController, NSSearchFieldDelegate,
    NSTableViewDataSource, NSTableViewDelegate {
    let searchField = NSSearchField()
    let tableView = CommandPaletteTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No matches")
    private var options: [CommandOption] = []
    private(set) var results: [CommandOption] = []
    private var finish: ((CommandOption?) -> Void)?
    private var isFinishing = false
    private var outsideClickMonitor: Any?
    private weak var previousFirstResponder: NSResponder?

    var query: String { searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    override func loadView() {
        view = NSView()
        searchField.placeholderString = "Execute a command…"
        searchField.font = .systemFont(ofSize: 20, weight: .light)
        searchField.isBordered = false
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel("Execute a command")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(activateClickedRow)
        tableView.setAccessibilityLabel("Commands")
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        emptyLabel.textColor = .secondaryLabelColor
        let divider = NSBox()
        divider.boxType = .separator
        for child in [searchField, divider, scrollView, emptyLabel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            searchField.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            searchField.heightAnchor.constraint(equalToConstant: 28),
            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            divider.topAnchor.constraint(equalTo: view.topAnchor, constant: 47),
            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 12)
        ])
        refreshResults()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        previousFirstResponder = view.window?.firstResponder
        view.window?.makeFirstResponder(searchField)
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let window = self.view.window, event.window === window else { return event }
            let point = self.view.convert(event.locationInWindow, from: nil)
            if !self.view.bounds.contains(point) { self.complete(nil) }
            return event
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        restoreFocus()
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    deinit {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
    }

    func update(options: [CommandOption], finish: @escaping (CommandOption?) -> Void) {
        self.finish = finish
        // The caller may recreate option IDs on a body update. Always replace
        // callbacks, but don't disturb the field editor or its marked text.
        self.options = options
        if isViewLoaded { refreshResults() }
    }

    func controlTextDidChange(_ notification: Notification) { refreshResults(queryChanged: true) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // The input method owns Return, Escape and arrows while composing.
        guard !textView.hasMarkedText() else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.cancelOperation(_:)):
            complete(nil)
        case #selector(NSResponder.insertNewline(_:)):
            let row = tableView.selectedRow
            complete(results.indices.contains(row) ? results[row] : nil)
        default:
            return false
        }
        return true
    }

    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let selected = tableView.selectedRow
        let next = selected < 0 ? (delta > 0 ? 0 : results.count - 1)
            : (selected + delta + results.count) % results.count
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    private func refreshResults(queryChanged: Bool = false) {
        let previous = tableView.selectedRow
        let oldResults = results
        results = query.isEmpty ? options : options.filteredAndSorted(query: query)
        // Action closures are replaced even if visible values did not change.
        // SwiftUI parent updates must not reload the table or reset scrolling.
        guard queryChanged || oldResults.map(rowSignature) != results.map(rowSignature) else { return }
        tableView.reloadData()
        emptyLabel.isHidden = !results.isEmpty
        var selected = previous
        if queryChanged {
            if !query.isEmpty && selected < 0 { selected = 0 }
            if query.isEmpty && selected == 0 { selected = -1 }
        }
        if selected >= 0 && !results.isEmpty {
            selected = min(selected, results.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
            if queryChanged { tableView.scrollRowToVisible(selected) }
        } else {
            tableView.deselectAll(nil)
        }
    }

    private func rowSignature(_ option: CommandOption) -> [String] {
        [option.title, option.subtitle ?? "", option.description ?? "", option.symbols?.joined() ?? "",
         option.leadingIcon ?? "", option.leadingColor.map { NSColor($0).description } ?? "",
         option.badge ?? "", String(option.emphasis)]
    }

    private func complete(_ option: CommandOption?) {
        guard !isFinishing else { return }
        isFinishing = true
        restoreFocus()
        finish?(option)
    }

    private func restoreFocus() {
        guard let window = view.window, let previousFirstResponder else { return }
        // Do not steal focus from an action or a click that already moved it.
        if window.firstResponder === searchField.currentEditor() || window.firstResponder === searchField {
            window.makeFirstResponder(previousFirstResponder)
        }
        self.previousFirstResponder = nil
    }

    @objc private func activateClickedRow() {
        let row = tableView.clickedRow
        guard results.indices.contains(row) else { return }
        complete(results[row])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        CommandPaletteRowView()
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        results[row].subtitle == nil && results[row].description == nil ? 32 : 48
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("commandCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? CommandPaletteCell
            ?? CommandPaletteCell()
        cell.identifier = identifier
        cell.configure(option: results[row], query: query)
        return cell
    }
}

/// Result clicks do not move the field editor away from the query.
final class CommandPaletteTableView: NSTableView {
    override var acceptsFirstResponder: Bool { false }
}

private final class CommandPaletteRowView: NSTableRowView {
    private var hoverArea: NSTrackingArea?
    private var hovered = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if hovered && !isSelected {
            NSColor.secondaryLabelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
    }
}

private final class CommandPaletteCell: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let dot = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let labels = NSStackView(views: [titleLabel, subtitleLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        let row = NSStackView(views: [dot, icon, labels, NSView(), badgeLabel, shortcutLabel])
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        shortcutLabel.font = .systemFont(ofSize: 12)
        shortcutLabel.textColor = .secondaryLabelColor
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        badgeLabel.font = .systemFont(ofSize: 10, weight: .medium)
        badgeLabel.textColor = .controlAccentColor
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(option: CommandOption, query: String) {
        titleLabel.attributedStringValue = highlighted(option.title, query: query,
            font: .systemFont(ofSize: 13, weight: option.emphasis ? .medium : .regular), color: .labelColor)
        let subtitle = option.subtitle ?? option.description
        subtitleLabel.isHidden = subtitle == nil
        subtitleLabel.attributedStringValue = highlighted(subtitle ?? "",
            query: option.title.matchedIndices(for: query) == nil ? query : "",
            font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        shortcutLabel.stringValue = option.symbols?.joined(separator: " ") ?? ""
        shortcutLabel.isHidden = option.symbols?.isEmpty ?? true
        badgeLabel.stringValue = option.badge ?? ""
        badgeLabel.isHidden = option.badge?.isEmpty ?? true
        icon.isHidden = option.leadingIcon == nil
        icon.image = option.leadingIcon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        icon.contentTintColor = option.emphasis ? .controlAccentColor : .secondaryLabelColor
        dot.isHidden = option.leadingColor == nil
        dot.layer?.backgroundColor = option.leadingColor.map { NSColor($0).cgColor }
        toolTip = option.description
        setAccessibilityLabel([option.title, subtitle, option.badge].compactMap { $0 }.joined(separator: ", "))
    }

    private func highlighted(_ value: String, query: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString(string: value, attributes: [.font: font, .foregroundColor: color])
        for index in value.matchedIndices(for: query) ?? [] {
            let range = NSRange(index..<value.index(after: index), in: value)
            result.addAttributes([.font: NSFont.boldSystemFont(ofSize: font.pointSize),
                                  .foregroundColor: NSColor.controlAccentColor], range: range)
        }
        return result
    }
}
