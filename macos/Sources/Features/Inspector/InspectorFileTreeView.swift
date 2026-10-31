import AppKit
import SwiftUI

struct InspectorFileTreeView: NSViewControllerRepresentable {
    let tree: InspectorFileTree
    let perform: (InspectorPaneActionKind) -> Void
    @Environment(\.colorScheme) private var colorScheme

    func makeNSViewController(context: Context) -> InspectorFileTreeController { InspectorFileTreeController() }
    func updateNSViewController(_ controller: InspectorFileTreeController, context: Context) {
        controller.update(tree, isLight: colorScheme == .light, perform: perform)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: InspectorFileTreeController, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

/// Snapshot adapter only: filesystem work and expansion state remain with the
/// provider. Stable item objects let AppKit retain selection and expanded rows.
final class InspectorFileTreeController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    final class Item: NSObject {
        var node: InspectorFileNode
        var children: [Item] = []
        init(_ node: InspectorFileNode) { self.node = node }
    }

    let outline = InspectorFilesOutlineView()
    let scrollView = NSScrollView()
    private let header = NSTextField(labelWithString: "")
    private(set) var items: [String: Item] = [:]
    private var roots: [Item] = []
    private var rootPath: String?
    private var lastTree: InspectorFileTree?
    private var isApplyingSnapshot = false
    private var isLight = false
    private var perform: (InspectorPaneActionKind) -> Void = { _ in }

    override func loadView() {
        view = NSView()
        header.font = .systemFont(ofSize: 11.5, weight: .medium)
        header.textColor = .secondaryLabelColor
        header.lineBreakMode = .byTruncatingMiddle
        header.maximumNumberOfLines = 1
        let column = NSTableColumn(identifier: .init("file"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 27
        outline.intercellSpacing = .zero
        outline.indentationPerLevel = InspectorTreeLayout.indent
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.autoresizingMask = [.width]
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(openClickedItem)
        outline.openSelection = { [weak self] in self?.openSelectedItem() }
        outline.renameSelection = { [weak self] in self?.renameSelectedItem() }
        outline.menuForItem = { [weak self] item in self?.menu(for: item) }
        outline.setAccessibilityLabel("Files")
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        for child in [header, scrollView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: InspectorContentMetrics.leadingInset),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -InspectorContentMetrics.leadingInset),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func update(_ tree: InspectorFileTree, isLight: Bool, perform: @escaping (InspectorPaneActionKind) -> Void) {
        _ = view
        self.perform = perform
        let themeChanged = self.isLight != isLight
        self.isLight = isLight
        if lastTree == tree, !themeChanged { return }
        lastTree = tree
        header.stringValue = tree.rootName
        header.toolTip = tree.rootPath
        let rootChanged = rootPath != tree.rootPath
        let selectedID = rootChanged ? nil : (outline.item(atRow: outline.selectedRow) as? Item)?.node.id
        let origin = scrollView.contentView.bounds.origin
        let topRow = outline.row(at: origin)
        let topID = rootChanged ? nil : (outline.item(atRow: topRow) as? Item)?.node.id
        let topOffset = topRow >= 0 ? origin.y - outline.rect(ofRow: topRow).minY : 0
        if rootChanged { items.removeAll() }
        var nextItems: [String: Item] = [:]
        var changedParents: [Item] = []
        var changedRows: [Item] = []
        func reconcile(_ nodes: [InspectorFileNode]) -> [Item] {
            nodes.map { node in
                let item = items[node.id] ?? Item(node)
                let old = item.node
                if old.name != node.name || old.icon != node.icon || old.isLoading != node.isLoading ||
                    old.isExpanded != node.isExpanded || old.isDirectory != node.isDirectory {
                    changedRows.append(item)
                }
                let previousChildren = item.children.map { $0.node.id }
                item.node = node
                item.children = reconcile(node.children ?? [])
                if previousChildren != item.children.map({ $0.node.id }) { changedParents.append(item) }
                nextItems[node.id] = item
                return item
            }
        }
        let previousRoots = roots.map { $0.node.id }
        roots = reconcile(tree.nodes)
        items = nextItems
        rootPath = tree.rootPath
        isApplyingSnapshot = true
        defer { isApplyingSnapshot = false }
        if rootChanged || previousRoots != roots.map({ $0.node.id }) {
            outline.reloadData()
        } else {
            // Reload only directories whose child identities changed; metadata
            // updates below do not rebuild the outline or reset its scroll.
            for item in changedParents where outline.row(forItem: item) >= 0 {
                outline.reloadItem(item, reloadChildren: true)
            }
        }
        func synchronizeExpansion(_ children: [Item]) {
            for item in children where item.node.isDirectory {
                if item.node.isExpanded {
                    if !outline.isItemExpanded(item) { outline.expandItem(item) }
                    synchronizeExpansion(item.children)
                } else if outline.isItemExpanded(item) {
                    outline.collapseItem(item, collapseChildren: true)
                }
            }
        }
        synchronizeExpansion(roots)
        let rowIndexes = themeChanged
            ? IndexSet(integersIn: 0..<outline.numberOfRows)
            : IndexSet(changedRows.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
        if !rowIndexes.isEmpty { outline.reloadData(forRowIndexes: rowIndexes, columnIndexes: IndexSet(integer: 0)) }
        if let selectedID, let item = items[selectedID], outline.row(forItem: item) >= 0 {
            outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: item)), byExtendingSelection: false)
        } else {
            outline.deselectAll(nil)
        }
        if let topID, let item = items[topID], outline.row(forItem: item) >= 0 {
            let y = outline.rect(ofRow: outline.row(forItem: item)).minY + topOffset
            scrollView.contentView.scroll(to: NSPoint(x: origin.x, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else if rootChanged {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Item)?.children.count ?? roots.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? Item)?.children ?? roots)[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Item)?.node.isDirectory == true
    }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { NativeHoverRowView() }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? Item else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("file")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? InspectorFileTreeCell
            ?? InspectorFileTreeCell()
        cell.identifier = identifier
        cell.configure(item.node, isLight: isLight)
        return cell
    }
    func outlineViewItemDidExpand(_ notification: Notification) { expansionChanged(notification, expanded: true) }
    func outlineViewItemDidCollapse(_ notification: Notification) { expansionChanged(notification, expanded: false) }

    private func expansionChanged(_ notification: Notification, expanded: Bool) {
        guard !isApplyingSnapshot, let item = notification.userInfo?["NSObject"] as? Item,
              item.node.isExpanded != expanded else { return }
        perform(.toggleNode(id: item.node.id, expanded: expanded))
    }
    @objc private func openClickedItem() { openItem(at: outline.clickedRow) }
    private func openSelectedItem() { openItem(at: outline.selectedRow) }
    private func openItem(at row: Int) {
        guard let item = outline.item(atRow: row) as? Item else { return }
        if item.node.isDirectory {
            if outline.isItemExpanded(item) { outline.collapseItem(item) } else { outline.expandItem(item) }
        } else {
            perform(.openFile(path: item.node.id))
        }
    }
    private func renameSelectedItem() {
        guard let item = outline.item(atRow: outline.selectedRow) as? Item else { return }
        perform(.renameFile(path: item.node.id))
    }

    func menu(for item: Item) -> NSMenu {
        let path = item.node.id
        let menu = NSMenu()
        func add(_ title: String, _ action: InspectorPaneActionKind, to menu: NSMenu) {
            let command = NSMenuItem(title: title, action: #selector(performMenuAction(_:)), keyEquivalent: "")
            command.target = self
            command.representedObject = MenuAction(action, perform: perform)
            menu.addItem(command)
        }
        add("Copy Path", .copyFilePath(path: path, relative: false), to: menu)
        add("Copy Relative Path", .copyFilePath(path: path, relative: true), to: menu)
        add("Rename…", .renameFile(path: path), to: menu)
        add("Open in…", .openFileExternally(path: path), to: menu)
        if !item.node.isDirectory {
            menu.addItem(.separator())
            add("Open in Editor", .openFile(path: path, destination: .currentPane), to: menu)
            let side = NSMenuItem(title: "Open to the Side", action: nil, keyEquivalent: "")
            let destinations = NSMenu()
            for destination in EditorOpenDestination.allCases {
                add(destination.title, .openFile(path: path, destination: destination), to: destinations)
            }
            side.submenu = destinations
            menu.addItem(side)
        }
        return menu
    }
    private final class MenuAction: NSObject {
        let action: InspectorPaneActionKind
        let perform: (InspectorPaneActionKind) -> Void
        init(_ action: InspectorPaneActionKind, perform: @escaping (InspectorPaneActionKind) -> Void) {
            self.action = action
            self.perform = perform
        }
    }
    @objc private func performMenuAction(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? MenuAction else { return }
        command.perform(command.action)
    }
}

final class InspectorFilesOutlineView: NSOutlineView {
    private lazy var hover = NativeTableHover(table: self)
    override func updateTrackingAreas() { super.updateTrackingAreas(); hover.update() }
    var openSelection: (() -> Void)?
    var renameSelection: (() -> Void)?
    var menuForItem: ((InspectorFileTreeController.Item) -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers.isEmpty {
            if event.keyCode == 36 || event.keyCode == 76 { openSelection?(); return }
            if event.keyCode == 120 { renameSelection?(); return }
        }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, let item = item(atRow: row) as? InspectorFileTreeController.Item else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return menuForItem?(item)
    }
}

private final class InspectorFileTreeCell: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let progress = NativeProgressIndicator()

    override init(frame: NSRect) {
        super.init(frame: frame)
        name.font = .systemFont(ofSize: 12.5)
        name.lineBreakMode = .byTruncatingMiddle
        name.maximumNumberOfLines = 1
        progress.style = .spinning
        progress.controlSize = .mini
        progress.isDisplayedWhenStopped = false
        for child in [icon, name, progress] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
            child.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.widthAnchor.constraint(equalToConstant: InspectorTreeLayout.iconWidth),
            icon.heightAnchor.constraint(equalToConstant: InspectorTreeLayout.iconWidth),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: InspectorTreeLayout.iconGap),
            name.trailingAnchor.constraint(equalTo: progress.leadingAnchor, constant: -4),
            progress.widthAnchor.constraint(equalToConstant: 12),
            progress.heightAnchor.constraint(equalToConstant: 12),
            progress.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
        textField = name
        imageView = icon
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ node: InspectorFileNode, isLight: Bool) {
        name.stringValue = node.name
        toolTip = node.id
        setAccessibilityIdentifier(node.id)
        if let asset = MaterialFileIcons.assetName(
            for: node.name, isDirectory: node.isDirectory, isExpanded: node.isExpanded, isLight: isLight
        ), let image = NSImage(named: asset) {
            icon.image = image
            icon.contentTintColor = nil
        } else {
            icon.image = NSImage(systemSymbolName: node.icon.systemImage, accessibilityDescription: nil)
            switch node.icon.tint {
            case .secondary: icon.contentTintColor = .secondaryLabelColor
            case .blue: icon.contentTintColor = .systemBlue
            case .green: icon.contentTintColor = .systemGreen
            case .orange: icon.contentTintColor = .systemOrange
            case .yellow: icon.contentTintColor = .systemYellow
            case .purple: icon.contentTintColor = .systemPurple
            case .red: icon.contentTintColor = .systemRed
            }
        }
        if node.isLoading { progress.setAnimating(true) } else { progress.setAnimating(false) }
    }
}
