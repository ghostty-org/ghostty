import AppKit
import Combine

/// A file or directory in the file explorer tree. Directory children are loaded lazily the
/// first time the directory is expanded.
final class FileExplorerNode {
    private(set) var entry: FileExplorerEntry

    /// The children of a directory, nil until they are loaded.
    var children: [FileExplorerNode]?

    var url: URL { entry.url }

    init(entry: FileExplorerEntry) {
        self.entry = entry
    }

    func update(entry: FileExplorerEntry) {
        self.entry = entry
    }
}

/// A Warp-style file explorer listing the working directory of the focused terminal of a
/// tab. It is shown in the tab sidebar when the sidebar is in files mode.
///
/// The tree root follows the working directory and the loaded directories are watched
/// with FSEvents so the tree stays up to date.
final class FileExplorerView: NSView {
    /// The controller of the window that hosts this explorer.
    private weak var controller: TerminalController?

    private let pathField: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 12, weight: .semibold)
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingMiddle
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setAccessibilityIdentifier("FileExplorerPath")
        return field
    }()

    private lazy var finderButton = makeButton(
        symbol: "folder",
        toolTip: "Open in Finder",
        identifier: "FileExplorerFinderButton",
        action: #selector(openRootInFinder(_:)))

    private lazy var hiddenButton = makeButton(
        symbol: "eye.slash",
        toolTip: "Show Hidden Files",
        identifier: "FileExplorerHiddenButton",
        action: #selector(toggleHiddenFiles(_:)))

    private lazy var refreshButton = makeButton(
        symbol: "arrow.clockwise",
        toolTip: "Refresh",
        identifier: "FileExplorerRefreshButton",
        action: #selector(refresh(_:)))

    private let scrollView = NSScrollView()
    private let outlineView = FileExplorerOutlineView()

    private let emptyField: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 12)
        field.textColor = .secondaryLabelColor
        field.alignment = .center
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }()

    /// The root of the tree: the working directory, with its symlinks resolved so paths
    /// match the paths reported by FSEvents.
    private var root: FileExplorerNode?

    /// The paths of the expanded directories, so expansion survives reloads.
    private var expandedPaths: Set<String> = []

    /// True when the directory changed while the window wasn't visible.
    private var needsReload = false

    private lazy var watcher = FileExplorerWatcher { [weak self] paths in
        self?.directoriesDidChange(paths)
    }

    private var cancellables: Set<AnyCancellable> = []

    init(controller: TerminalController) {
        self.controller = controller
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Setup

    private func setup() {
        setAccessibilityIdentifier("FileExplorer")

        let buttons = NSStackView(views: [hiddenButton, refreshButton, finderButton])
        buttons.orientation = .horizontal
        buttons.spacing = 2
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(pathField)
        addSubview(buttons)

        // The column always spans the visible width, see `syncColumnWidth`.
        let column = NSTableColumn(identifier: .init("file"))
        column.resizingMask = []
        column.minWidth = 0
        column.maxWidth = .greatestFiniteMagnitude
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 22
        outlineView.indentationPerLevel = 14
        outlineView.backgroundColor = .clear
        outlineView.style = .plain
        outlineView.columnAutoresizingStyle = .noColumnAutoresizing
        outlineView.autoresizesOutlineColumn = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked(_:))
        outlineView.doubleAction = #selector(rowDoubleClicked(_:))
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)
        outlineView.setAccessibilityIdentifier("FileExplorerTree")

        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        addSubview(emptyField)

        NSLayoutConstraint.activate([
            pathField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            pathField.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            pathField.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -6),

            buttons.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            scrollView.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyField.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 24),
            emptyField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            emptyField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])

        // @Published emits before the property changes so we reload on the next turn.
        TabSidebarSettings.shared.$showHiddenFiles
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.showHiddenFilesDidChange() }
            .store(in: &cancellables)
        updateHiddenButton()

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(onItemDidChange(_:)),
            name: .terminalTabSidebarItemDidChange,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil)
    }

    private func makeButton(symbol: String, toolTip: String, identifier: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.refusesFirstResponder = true
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = toolTip
        button.setAccessibilityLabel(toolTip)
        button.target = self
        button.action = action
        button.setAccessibilityIdentifier(identifier)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24),
        ])
        return button
    }

    override func layout() {
        super.layout()
        syncColumnWidth()
    }

    /// Makes the single column exactly as wide as the visible area (see `TabSidebarView`).
    private func syncColumnWidth() {
        guard let column = outlineView.tableColumns.first else { return }
        let width = max(0, scrollView.contentView.bounds.width - outlineView.intercellSpacing.width)
        guard abs(column.width - width) > 0.5 else { return }
        column.width = width
    }

    // MARK: Activation

    /// The explorer only reads and watches the file system while it can be seen.
    private var isActive: Bool {
        window != nil && !isHiddenOrHasHiddenAncestor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        activeStateDidChange()
    }

    override func viewDidHide() {
        super.viewDidHide()
        activeStateDidChange()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        activeStateDidChange()
    }

    private func activeStateDidChange() {
        if isActive {
            syncRoot()
        } else {
            watcher.stop()
        }
    }

    @objc private func onItemDidChange(_ notification: Notification) {
        guard notification.object as? TerminalController === controller else { return }

        // The pwd publisher emits before its value changes.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive else { return }
            self.syncRoot()
        }
    }

    @objc private func onWindowDidBecomeKey(_ notification: Notification) {
        guard notification.object as? NSWindow === window, needsReload, isActive else { return }
        reloadLoadedDirectories()
    }

    // MARK: Tree

    /// The URL of the working directory of the focused terminal.
    private var workingDirectoryURL: URL? {
        guard let pwd = controller?.focusedSurface?.pwd, !pwd.isEmpty else { return nil }
        return URL(fileURLWithPath: pwd, isDirectory: true).resolvingSymlinksInPath()
    }

    /// Makes the tree root follow the working directory. If the root didn't change we only
    /// reload when something changed while we weren't looking.
    private func syncRoot() {
        let url = workingDirectoryURL
        if url?.path != root?.url.path {
            setRoot(url)
        } else if needsReload {
            reloadLoadedDirectories()
        }

        if let root {
            watcher.start(path: root.url.path)
        } else {
            watcher.stop()
        }
    }

    private func setRoot(_ url: URL?) {
        needsReload = false
        expandedPaths = []
        root = url.map { url in
            let node = FileExplorerNode(entry: FileExplorerEntry(
                url: url,
                name: url.lastPathComponent,
                isDirectory: true,
                isHidden: false))
            node.children = loadChildren(of: node)
            return node
        }

        outlineView.reloadData()
        outlineView.scrollRowToVisible(0)
        updateHeader()
    }

    private func loadChildren(of node: FileExplorerNode) -> [FileExplorerNode] {
        let showHidden = TabSidebarSettings.shared.showHiddenFiles
        return FileExplorerLogic.listDirectory(node.url, showHidden: showHidden).map(FileExplorerNode.init(entry:))
    }

    /// Re-lists a loaded directory. Existing nodes are reused so their children and
    /// expansion are kept.
    private func reload(_ node: FileExplorerNode) {
        guard let oldChildren = node.children else { return }
        var existing: [String: FileExplorerNode] = [:]
        for child in oldChildren { existing[child.url.path] = child }

        let showHidden = TabSidebarSettings.shared.showHiddenFiles
        node.children = FileExplorerLogic.listDirectory(node.url, showHidden: showHidden).map { entry in
            guard let child = existing[entry.url.path], child.entry.isDirectory == entry.isDirectory else {
                return FileExplorerNode(entry: entry)
            }
            child.update(entry: entry)
            return child
        }

        outlineView.reloadItem(node === root ? nil : node, reloadChildren: true)
        restoreExpansion(of: node.children ?? [])
    }

    /// Re-expands the directories that were expanded before a reload.
    private func restoreExpansion(of nodes: [FileExplorerNode]) {
        for node in nodes where node.entry.isDirectory && expandedPaths.contains(node.url.path) {
            outlineView.expandItem(node)
            restoreExpansion(of: node.children ?? [])
        }
    }

    /// Reloads every directory that has been loaded, parents before children.
    private func reloadLoadedDirectories() {
        needsReload = false
        guard let root else { return }
        var queue = [root]
        while !queue.isEmpty {
            let node = queue.removeFirst()
            reload(node)
            queue.append(contentsOf: (node.children ?? []).filter { $0.children != nil })
        }
        updateHeader()
    }

    /// Finds the loaded node of the directory at the given path.
    private func node(forPath path: String) -> FileExplorerNode? {
        guard let root else { return nil }
        let rootPath = root.url.path
        if path == rootPath { return root }

        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }

        var node = root
        for component in path.dropFirst(prefix.count).split(separator: "/") {
            guard let child = node.children?.first(where: { $0.entry.name == component }) else { return nil }
            node = child
        }
        return node
    }

    private func directoriesDidChange(_ paths: [String]) {
        guard let root else { return }

        // Background tabs catch up once they are shown again.
        guard let window, window.isVisible, isActive else {
            needsReload = true
            return
        }

        // The root itself was moved or deleted.
        if !FileManager.default.fileExists(atPath: root.url.path) {
            reloadLoadedDirectories()
            return
        }

        for path in Set(paths) {
            guard let node = node(forPath: path), node.children != nil else { continue }
            reload(node)
        }
        updateHeader()
    }

    private func showHiddenFilesDidChange() {
        updateHiddenButton()
        if isActive {
            reloadLoadedDirectories()
        } else {
            needsReload = true
        }
    }

    // MARK: Header

    private func updateHeader() {
        let pwd = controller?.focusedSurface?.pwd
        let path = TabSidebarLogic.abbreviatePath(pwd)
        pathField.stringValue = path.map(TabSidebarLogic.directoryName) ?? ""
        pathField.toolTip = pwd
        finderButton.isEnabled = root != nil
        refreshButton.isEnabled = root != nil

        if root == nil {
            emptyField.stringValue = "No Working Directory"
            emptyField.isHidden = false
        } else if root?.children?.isEmpty ?? true {
            let readable = root.map { FileManager.default.isReadableFile(atPath: $0.url.path) } ?? false
            emptyField.stringValue = readable ? "Empty Folder" : "Folder Can't Be Read"
            emptyField.isHidden = false
        } else {
            emptyField.isHidden = true
        }
    }

    private func updateHiddenButton() {
        let showHidden = TabSidebarSettings.shared.showHiddenFiles
        let toolTip = showHidden ? "Hide Hidden Files" : "Show Hidden Files"
        hiddenButton.image = NSImage(systemSymbolName: showHidden ? "eye" : "eye.slash", accessibilityDescription: toolTip)
        hiddenButton.toolTip = toolTip
        hiddenButton.setAccessibilityLabel(toolTip)
    }

    // MARK: Actions

    @objc private func openRootInFinder(_ sender: Any?) {
        guard let root else { return }
        NSWorkspace.shared.open(root.url)
    }

    @objc private func toggleHiddenFiles(_ sender: Any?) {
        TabSidebarSettings.shared.showHiddenFiles.toggle()
    }

    @objc private func refresh(_ sender: Any?) {
        reloadLoadedDirectories()
    }

    @objc private func rowClicked(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard let node = outlineView.item(atRow: row) as? FileExplorerNode else { return }

        // Clicks on the disclosure triangle already toggled the directory.
        if let event = NSApp.currentEvent {
            let point = outlineView.convert(event.locationInWindow, from: nil)
            if outlineView.frameOfOutlineCell(atRow: row).contains(point) { return }
        }

        if node.entry.isDirectory {
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
        } else {
            preview(node)
        }
    }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? FileExplorerNode,
              !node.entry.isDirectory else { return }
        NSWorkspace.shared.open(node.url)
    }

    private func preview(_ node: FileExplorerNode) {
        controller?.terminalViewContainer?.showFilePreview(node.url)
    }
}

// MARK: NSOutlineViewDataSource / NSOutlineViewDelegate

extension FileExplorerView: NSOutlineViewDataSource, NSOutlineViewDelegate {
    private func children(of item: Any?) -> [FileExplorerNode] {
        guard let node = item as? FileExplorerNode ?? root else { return [] }
        return node.children ?? []
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileExplorerNode)?.entry.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileExplorerNode else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("FileExplorerCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? FileExplorerCellView
            ?? FileExplorerCellView(frame: .zero)
        cell.identifier = identifier
        cell.configure(with: node.entry)
        return cell
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileExplorerNode,
              node.children == nil else { return }
        node.children = loadChildren(of: node)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileExplorerNode else { return }
        expandedPaths.insert(node.url.path)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileExplorerNode else { return }
        expandedPaths.remove(node.url.path)
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        (item as? FileExplorerNode)?.url as NSURL?
    }
}

// MARK: Context Menu

extension FileExplorerView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? FileExplorerNode else { return }

        func item(_ title: String, _ action: Selector, symbol: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = node
            item.setImageIfDesired(systemSymbolName: symbol)
            return item
        }

        if !node.entry.isDirectory {
            menu.addItem(item("Preview", #selector(previewFromMenu(_:)), symbol: "eye"))
        }
        menu.addItem(item("Open with Default App", #selector(openFromMenu(_:)), symbol: "arrow.up.forward.app"))
        menu.addItem(item("Reveal in Finder", #selector(revealInFinder(_:)), symbol: "folder"))
        menu.addItem(.separator())
        menu.addItem(item("Copy Path", #selector(copyPath(_:)), symbol: "doc.on.doc"))
        menu.addItem(item("Insert Path into Terminal", #selector(insertPath(_:)), symbol: "terminal"))
        menu.addItem(.separator())
        menu.addItem(item("Refresh", #selector(refresh(_:)), symbol: "arrow.clockwise"))
    }

    private func menuTarget(_ sender: Any?) -> FileExplorerNode? {
        (sender as? NSMenuItem)?.representedObject as? FileExplorerNode
    }

    @objc private func previewFromMenu(_ sender: Any?) {
        guard let node = menuTarget(sender) else { return }
        preview(node)
    }

    @objc private func openFromMenu(_ sender: Any?) {
        guard let node = menuTarget(sender) else { return }
        NSWorkspace.shared.open(node.url)
    }

    @objc private func revealInFinder(_ sender: Any?) {
        guard let node = menuTarget(sender) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    @objc private func copyPath(_ sender: Any?) {
        guard let node = menuTarget(sender) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(node.url.path, forType: .string)
    }

    @objc private func insertPath(_ sender: Any?) {
        guard let node = menuTarget(sender),
              let surface = controller?.focusedSurface else { return }
        surface.surfaceModel?.sendText(Ghostty.Shell.escape(node.url.path))
        window?.makeFirstResponder(surface)
    }
}

// MARK: Subviews

/// The outline view of the explorer. Like the tab list it never takes focus away from
/// the terminal.
final class FileExplorerOutlineView: NSOutlineView {
    override var acceptsFirstResponder: Bool { false }
}

/// A row of the explorer: the file icon and name.
final class FileExplorerCellView: NSTableCellView {
    private let iconView: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let nameField: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingMiddle
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView = iconView
        textField = nameField
        addSubview(iconView)
        addSubview(nameField)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            nameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            nameField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with entry: FileExplorerEntry) {
        iconView.image = NSWorkspace.shared.icon(forFile: entry.url.path)
        nameField.stringValue = entry.name
        nameField.toolTip = entry.url.path
        nameField.textColor = entry.isHidden ? .secondaryLabelColor : .labelColor
    }
}
