import AppKit
import SwiftUI

/// AppKit-backed transcript renderer. NSTableView reuses only visible rows and
/// caches dynamic row heights, avoiding SwiftUI's repeated whole-list text
/// measurement during high-velocity scrolling.
struct AgentHistoryTranscriptTable: NSViewRepresentable {
    let messages: [AgentHistoryMessage]
    let agentName: String
    let strings: AgentHistoryStrings
    let highlightText: String
    let onFork: () -> Void
    var onFind: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = AgentHistoryTranscriptScrollView()
        scrollView.onFind = onFind
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let tableView = NSTableView()
        tableView.backgroundColor = .clear
        tableView.headerView = nil
        tableView.intercellSpacing = NSSize(width: 0, height: 8)
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = true
        tableView.usesAutomaticRowHeights = true
        tableView.rowHeight = 48

        let column = NSTableColumn(identifier: .init("agent-history-message"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        scrollView.documentView = tableView

        context.coordinator.tableView = tableView
        context.coordinator.update(
            messages: messages,
            agentName: agentName,
            strings: strings,
            highlightText: highlightText,
            onFork: onFork
        )
        context.coordinator.updateWidth(scrollView.contentSize.width)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        (scrollView as? AgentHistoryTranscriptScrollView)?.onFind = onFind
        context.coordinator.update(
            messages: messages,
            agentName: agentName,
            strings: strings,
            highlightText: highlightText,
            onFork: onFork
        )
        guard let tableView = scrollView.documentView as? NSTableView else { return }
        tableView.sizeLastColumnToFit()
        context.coordinator.updateWidth(scrollView.contentSize.width)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var tableView: NSTableView?
        private var messages: [AgentHistoryMessage] = []
        private var agentName = "Agent"
        private var strings = AgentHistoryStrings()
        private var highlightText = ""
        private var onFork: () -> Void = {}
        private var lastWidth: CGFloat = 0

        func update(
            messages: [AgentHistoryMessage],
            agentName: String,
            strings: AgentHistoryStrings,
            highlightText: String,
            onFork: @escaping () -> Void
        ) {
            let contentChanged = self.messages != messages ||
                self.agentName != agentName ||
                self.strings != strings ||
                self.highlightText != highlightText
            self.messages = messages
            self.agentName = agentName
            self.strings = strings
            self.highlightText = highlightText
            self.onFork = onFork
            guard contentChanged, let tableView else { return }
            tableView.reloadData()
            tableView.noteHeightOfRows(
                withIndexesChanged: IndexSet(integersIn: 0..<messages.count)
            )
        }

        func updateWidth(_ width: CGFloat) {
            guard abs(lastWidth - width) > 1, let tableView else { return }
            lastWidth = width
            guard !messages.isEmpty else { return }
            tableView.noteHeightOfRows(
                withIndexesChanged: IndexSet(integersIn: 0..<messages.count)
            )
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            messages.count
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard messages.indices.contains(row) else { return nil }
            let identifier = AgentHistoryTranscriptCell.reuseIdentifier
            let cell = tableView.makeView(
                withIdentifier: identifier,
                owner: nil
            ) as? AgentHistoryTranscriptCell ?? AgentHistoryTranscriptCell()
            cell.identifier = identifier
            cell.configure(
                message: messages[row],
                agentName: agentName,
                strings: strings,
                highlightText: highlightText,
                onFork: onFork
            )
            return cell
        }
    }
}

final class AgentHistoryTranscriptScrollView: NSScrollView {
    var onFind: () -> Void = {}

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if AgentHistoryFindShortcut.accepts(event, in: self) {
            onFind()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class AgentHistoryTranscriptCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier(
        "agent-history-transcript-cell"
    )

    private let roleLabel = NSTextField(labelWithString: "")
    private let messageField = NSTextField(wrappingLabelWithString: "")
    private let copyButton = NSButton()
    private let forkButton = NSButton()
    private let actionStack = NSStackView()
    private let contentStack = NSStackView()
    private var trackingArea: NSTrackingArea?
    private var message: AgentHistoryMessage?
    private var onFork: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        roleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        roleLabel.setContentHuggingPriority(.required, for: .vertical)

        messageField.isEditable = false
        messageField.isSelectable = true
        messageField.drawsBackground = false
        messageField.isBordered = false
        messageField.font = .systemFont(ofSize: 12.5)
        messageField.maximumNumberOfLines = 0
        messageField.lineBreakMode = .byWordWrapping
        messageField.setContentCompressionResistancePriority(.required, for: .vertical)
        messageField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configureButton(
            copyButton,
            symbol: "doc.on.doc",
            action: #selector(copyMessage)
        )
        configureButton(
            forkButton,
            symbol: "arrow.triangle.branch",
            action: #selector(forkMessage)
        )
        actionStack.orientation = .horizontal
        actionStack.spacing = 4
        actionStack.addArrangedSubview(copyButton)
        actionStack.addArrangedSubview(forkButton)
        actionStack.alphaValue = 0

        let headerStack = NSStackView(views: [roleLabel, NSView(), actionStack])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 6

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 5
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(headerStack)
        contentStack.addArrangedSubview(messageField)
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            headerStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            messageField.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        actionStack.alphaValue = 1
    }

    override func mouseExited(with event: NSEvent) {
        actionStack.alphaValue = 0
    }

    func configure(
        message: AgentHistoryMessage,
        agentName: String,
        strings: AgentHistoryStrings,
        highlightText: String,
        onFork: @escaping () -> Void
    ) {
        self.message = message
        self.onFork = onFork
        roleLabel.stringValue = message.role == .user ? strings.you : agentName
        roleLabel.textColor = message.role == .user ? .systemBlue : .secondaryLabelColor
        layer?.backgroundColor = (
            message.role == .user
                ? NSColor.systemBlue.withAlphaComponent(0.08)
                : NSColor.labelColor.withAlphaComponent(0.05)
        ).cgColor
        copyButton.toolTip = strings.copyMessage
        forkButton.toolTip = strings.forkSession
        forkButton.isHidden = message.role != .assistant
        messageField.attributedStringValue = Self.attributedText(
            message.text,
            highlight: highlightText
        )
    }

    private func configureButton(
        _ button: NSButton,
        symbol: String,
        action: Selector
    ) {
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: nil
        )
        button.isBordered = false
        button.bezelStyle = .inline
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = action
    }

    @objc private func copyMessage() {
        guard let message else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
    }

    @objc private func forkMessage() {
        onFork?()
    }

    private static func attributedText(
        _ text: String,
        highlight: String
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12.5),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        guard !highlight.isEmpty else { return result }
        let source = text as NSString
        var searchRange = NSRange(location: 0, length: source.length)
        while searchRange.location < source.length {
            let range = source.range(
                of: highlight,
                options: .caseInsensitive,
                range: searchRange
            )
            guard range.location != NSNotFound else { break }
            result.addAttributes([
                .backgroundColor: NSColor.systemYellow.withAlphaComponent(0.4),
                .font: NSFont.boldSystemFont(ofSize: 12.5),
            ], range: range)
            let next = range.location + range.length
            searchRange = NSRange(location: next, length: source.length - next)
        }
        return result
    }
}
