import AppKit
import SwiftUI

/// Flattened native rows retain stable identity through search, grouping and paging.
enum InspectorAgentHistoryListRow: Equatable {
    case group(id: String, title: String, count: Int, collapsed: Bool)
    case session(AgentHistorySession, snippet: String?)
    case more(remaining: Int)

    var id: String {
        switch self {
        case let .group(id, _, _, _): return "group:" + id
        case let .session(session, _): return "session:" + session.id
        case .more: return "more"
        }
    }

    var height: CGFloat {
        switch self {
        case .group: return 28
        case .more: return 38
        case let .session(session, snippet):
            return snippet != nil ? 104 : (session.workingDirectory != nil ? 88 : 70)
        }
    }
}

struct InspectorAgentHistoryList: NSViewControllerRepresentable {
    let rows: [InspectorAgentHistoryListRow]
    let query: String
    let strings: AgentHistoryStrings
    let select: (AgentHistorySession) -> Void
    let toggleGroup: (String) -> Void
    let loadMore: () -> Void
    let perform: (InspectorPaneActionKind) -> Void

    func makeNSViewController(context: Context) -> InspectorAgentHistoryListController {
        InspectorAgentHistoryListController()
    }

    func updateNSViewController(_ controller: InspectorAgentHistoryListController, context: Context) {
        controller.update(self)
    }
}

final class InspectorAgentHistoryListController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let scroll = NSScrollView()
    private let table = InspectorAgentSessionTable()
    private var snapshot: InspectorAgentHistoryList?
    private var rows: [InspectorAgentHistoryListRow] = []
    private var scrollObserver: NSObjectProtocol?
    private var pendingPage = false
    private var revision = 0

    override func loadView() {
        view = scroll
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(activateClickedRow)
        table.onActivate = { [weak self] in self?.activate(self?.table.selectedRow ?? -1) }
        table.onDisclosure = { [weak self] expand in
            guard let self, self.rows.indices.contains(self.table.selectedRow),
                  case let .group(id, _, _, collapsed) = self.rows[self.table.selectedRow],
                  expand == collapsed else { return }
            self.snapshot?.toggleGroup(id)
        }
        table.contextMenu = { [weak self] row in self?.menu(for: row) }
        scroll.documentView = table
        scroll.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestPageIfVisible() }
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        requestPageIfVisible()
    }

    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    func update(_ next: InspectorAgentHistoryList) {
        _ = view
        let queryChanged = snapshot?.query != next.query
        let contentChanged = queryChanged || snapshot?.strings != next.strings
        if queryChanged {
            revision &+= 1
            pendingPage = false
        }
        snapshot = next
        if rows != next.rows {
            revision &+= 1
            pendingPage = false
            let previous = rows
            let selectedID = previous.indices.contains(table.selectedRow) ? previous[table.selectedRow].id : nil
            let oldOrigin = scroll.contentView.bounds.origin
            let topRow = table.row(at: NSPoint(x: 1, y: oldOrigin.y))
            let topID = previous.indices.contains(topRow) ? previous[topRow].id : nil
            let topOffset = topRow >= 0 ? oldOrigin.y - table.rect(ofRow: topRow).minY : 0
            let difference = next.rows.map(\.id).difference(from: previous.map(\.id))
            rows = next.rows
            table.beginUpdates()
            for change in difference {
                switch change {
                case let .remove(offset, _, _): table.removeRows(at: IndexSet(integer: offset), withAnimation: [])
                case let .insert(offset, _, _): table.insertRows(at: IndexSet(integer: offset), withAnimation: [])
                }
            }
            table.endUpdates()
            let oldByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
            let changed = IndexSet(rows.indices.filter { oldByID[rows[$0].id] != rows[$0] })
            table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
            table.noteHeightOfRows(withIndexesChanged: changed)
            let selection = rows.firstIndex { $0.id == selectedID }
            table.selectRowIndexes(selection.map { IndexSet(integer: $0) } ?? [], byExtendingSelection: false)
            if let topID, let index = rows.firstIndex(where: { $0.id == topID }) {
                scroll.contentView.scroll(to: NSPoint(x: oldOrigin.x, y: table.rect(ofRow: index).minY + topOffset))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        if contentChanged, !rows.isEmpty {
            table.reloadData(forRowIndexes: IndexSet(rows.indices), columnIndexes: IndexSet(integer: 0))
        }
        requestPageIfVisible()
    }

    private func requestPageIfVisible() {
        guard !pendingPage, view.window != nil, !view.isHiddenOrHasHiddenAncestor,
              scroll.contentView.bounds.height > 0,
              let last = rows.last, case .more = last,
              table.rect(ofRow: rows.count - 1).intersects(scroll.contentView.bounds) else { return }
        pendingPage = true
        let requestedRevision = revision
        DispatchQueue.main.async { [weak self] in
            guard let self, self.revision == requestedRevision, self.view.window != nil,
                  !self.view.isHiddenOrHasHiddenAncestor else {
                self?.pendingPage = false
                return
            }
            self.snapshot?.loadMore()
        }
    }

    @objc private func activateClickedRow() { activate(table.clickedRow) }

    private func activate(_ row: Int) {
        guard rows.indices.contains(row) else { return }
        switch rows[row] {
        case let .session(session, _): snapshot?.select(session)
        case let .group(id, _, _, _): snapshot?.toggleGroup(id)
        case .more:
            guard !pendingPage else { return }
            pendingPage = true
            snapshot?.loadMore()
        }
    }

    func menu(for row: Int) -> NSMenu? {
        guard rows.indices.contains(row), case let .session(session, _) = rows[row], let snapshot else { return nil }
        let menu = NSMenu()
        let resume = NSMenuItem(title: session.isActive ? snapshot.strings.openLive : snapshot.strings.resume,
                                action: #selector(resumeSession(_:)), keyEquivalent: "")
        resume.target = self
        resume.representedObject = MenuAction(action: .resumeAgentHistorySession(id: session.id), perform: snapshot.perform)
        menu.addItem(resume)
        if session.remoteHost == nil {
            let fork = NSMenuItem(title: snapshot.strings.forkSession, action: #selector(forkSession(_:)), keyEquivalent: "")
            fork.target = self
            fork.representedObject = MenuAction(action: .forkAgentHistorySession(id: session.id), perform: snapshot.perform)
            menu.addItem(fork)
        }
        return menu
    }

    @objc private func resumeSession(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.perform()
    }

    @objc private func forkSession(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.perform()
    }

    private final class MenuAction: NSObject {
        private let action: InspectorPaneActionKind
        private let callback: (InspectorPaneActionKind) -> Void
        init(action: InspectorPaneActionKind, perform: @escaping (InspectorPaneActionKind) -> Void) {
            self.action = action
            self.callback = perform
        }
        func perform() { callback(action) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row].height }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let snapshot else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("agent-history-row")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? InspectorAgentSessionCell
            ?? InspectorAgentSessionCell()
        cell.identifier = identifier
        cell.configure(rows[row], query: snapshot.query, strings: snapshot.strings)
        let id = rows[row].id
        cell.onActivate = { [weak self] in
            guard let self, let row = self.rows.firstIndex(where: { $0.id == id }) else { return }
            self.activate(row)
        }
        return cell
    }
}

private final class InspectorAgentSessionTable: NSTableView {
    var onActivate: (() -> Void)?
    var onDisclosure: ((Bool) -> Void)?
    var contextMenu: ((Int) -> NSMenu?)?
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]) {
            switch event.keyCode {
            case 36, 76: onActivate?(); return
            case 123: onDisclosure?(false); return
            case 124: onDisclosure?(true); return
            default: break
            }
        }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return contextMenu?(row)
    }
}

private final class InspectorAgentSessionCell: NSTableCellView {
    private let icon = NSImageView()
    private let heading = NSTextField(wrappingLabelWithString: "")
    private let metadata = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private var isSession = false
    var onActivate: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        [icon, heading, metadata, detail, status].forEach(addSubview)
        heading.maximumNumberOfLines = 2
        heading.lineBreakMode = .byTruncatingTail
        metadata.font = .systemFont(ofSize: 11)
        metadata.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .tertiaryLabelColor
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byTruncatingTail
        status.font = .systemFont(ofSize: 10, weight: .semibold)
        status.textColor = .systemGreen
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func accessibilityPerformPress() -> Bool { onActivate?(); return onActivate != nil }

    override func layout() {
        super.layout()
        if isSession {
            icon.frame = NSRect(x: 12, y: 10, width: 20, height: 20)
            heading.frame = NSRect(x: 41, y: 9, width: max(0, bounds.width - 53 - (status.isHidden ? 0 : 36)), height: 32)
            status.frame = NSRect(x: bounds.width - 47, y: 10, width: 35, height: 15)
            metadata.frame = NSRect(x: 41, y: 43, width: max(0, bounds.width - 53), height: 16)
            detail.frame = NSRect(x: 41, y: 62, width: max(0, bounds.width - 53), height: max(0, bounds.height - 70))
        } else {
            icon.frame = NSRect(x: 12, y: 8, width: 10, height: 12)
            heading.frame = NSRect(x: 28, y: 6, width: max(0, bounds.width - 72), height: bounds.height - 10)
            metadata.frame = NSRect(x: bounds.width - 40, y: 6, width: 28, height: 16)
        }
    }

    func configure(_ row: InspectorAgentHistoryListRow, query: String, strings: AgentHistoryStrings) {
        status.isHidden = true
        detail.isHidden = true
        metadata.isHidden = false
        heading.font = .systemFont(ofSize: 12.5, weight: .medium)
        switch row {
        case let .session(session, snippet):
            isSession = true
            icon.image = NSImage(named: session.agent.assetName)
            heading.attributedStringValue = highlighted(session.title, query: query, size: 12.5, color: .labelColor)
            metadata.stringValue = "\(session.agent.displayName) · \(strings.relativeTime(from: session.updatedAt))"
            status.stringValue = strings.live
            status.isHidden = !session.isActive
            if let snippet {
                detail.attributedStringValue = highlighted(snippet, query: query, size: 10, color: .secondaryLabelColor)
                detail.isHidden = false
            } else if let directory = session.workingDirectory {
                detail.stringValue = directory
                detail.isHidden = false
            }
            toolTip = session.title
        case let .group(_, title, count, collapsed):
            isSession = false
            heading.stringValue = title
            heading.font = .systemFont(ofSize: 11.5, weight: .semibold)
            metadata.stringValue = String(count)
            icon.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)
            toolTip = title
        case let .more(remaining):
            isSession = false
            metadata.stringValue = ""
            heading.stringValue = strings.loadMoreSessions(remaining)
            metadata.isHidden = true
            icon.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
            toolTip = nil
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(heading.stringValue + ", " + metadata.stringValue)
        needsLayout = true
    }

    private func highlighted(_ text: String, query: String, size: CGFloat, color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: color,
        ])
        guard !query.isEmpty else { return result }
        let source = text as NSString
        var remaining = NSRange(location: 0, length: source.length)
        while remaining.length > 0 {
            let match = source.range(of: query, options: .caseInsensitive, range: remaining)
            guard match.location != NSNotFound, match.length > 0 else { break }
            result.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.45), range: match)
            let end = NSMaxRange(match)
            remaining = NSRange(location: end, length: source.length - end)
        }
        return result
    }
}
