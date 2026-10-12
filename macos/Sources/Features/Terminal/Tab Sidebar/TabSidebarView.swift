import AppKit

extension NSPasteboard.PasteboardType {
    /// Pasteboard type used to reorder rows within the tab sidebar.
    static let ghosttyTabSidebarRow = NSPasteboard.PasteboardType("com.mitchellh.ghostty.tab-sidebar-row")
}

/// A Warp-style vertical list of the tabs in a window's tab group.
///
/// Every tab in Ghostty is its own `NSWindow` grouped by AppKit's native tab group, so
/// every tab window has its own sidebar. Each sidebar is a read-only view of
/// `tabGroup.windows`. App-wide state (width, visibility) lives in `TabSidebarSettings`
/// so all sidebars look identical and switching tabs doesn't visibly change anything
/// but the highlighted row.
final class TabSidebarView: NSView {
    /// The controller of the window that hosts this sidebar.
    private weak var controller: TerminalController?

    private let header = TabSidebarHeaderView()
    private let scrollView = NSScrollView()
    private let tableView = TabSidebarTableView()
    private let resizeHandle = TabSidebarResizeHandle()

    /// The tabs shown in the sidebar, in tab group order.
    private var tabs: [Weak<TerminalController>] = []

    /// The tab group we're observing for changes to its windows.
    private weak var observedTabGroup: NSWindowTabGroup?
    private var windowsObservation: NSKeyValueObservation?

    /// True once it is cheap to access the tab group of our window (see `reloadStructure`).
    private var canAccessTabGroup = false

    /// True when a content reload is scheduled on the next main loop turn.
    private var pendingContentReload = false

    /// The background color of the sidebar, derived from the terminal background.
    private var sidebarBackgroundColor: NSColor = .windowBackgroundColor

    /// The inline title editor state.
    private weak var editingController: TerminalController?
    private weak var editingField: NSTextField?
    private var isFinishingEdit = false
    private var editingClickMonitor: Any?

    /// A click on a row of another tab switches windows, so the second click of a
    /// double click lands in the sidebar of the other window. We track the last
    /// switching click so we can still detect the double click there.
    private static var lastSwitchClick: (tab: ObjectIdentifier, time: TimeInterval)?

    /// Prevents re-entrancy when syncing the scroll position across sidebars.
    private static var isSyncingScroll = false

    init(controller: TerminalController) {
        self.controller = controller
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let editingClickMonitor {
            NSEvent.removeMonitor(editingClickMonitor)
        }
    }

    // MARK: Setup

    private func setup() {
        setAccessibilityIdentifier("TabSidebarContainer")

        header.translatesAutoresizingMaskIntoConstraints = false
        header.newTabButton.target = self
        header.newTabButton.action = #selector(newTabClicked(_:))
        addSubview(header)

        // The column always spans the visible width (see `syncColumnWidth`) so the
        // close button sits at the trailing edge of the row.
        let column = NSTableColumn(identifier: .init("tab"))
        column.resizingMask = []
        column.minWidth = 0
        column.maxWidth = .greatestFiniteMagnitude
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 44
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.style = .plain
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked(_:))
        tableView.doubleAction = #selector(rowDoubleClicked(_:))
        tableView.registerForDraggedTypes([.ghosttyTabSidebarRow])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.setAccessibilityIdentifier("TabSidebar")

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        addSubview(scrollView)

        resizeHandle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(resizeHandle)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 32),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            resizeHandle.topAnchor.constraint(equalTo: topAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: bottomAnchor),
            resizeHandle.trailingAnchor.constraint(equalTo: trailingAnchor),
            resizeHandle.widthAnchor.constraint(equalToConstant: 6),
        ])

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(onNeedsReload(_:)),
            name: .terminalTabSidebarNeedsReload,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onItemDidChange(_:)),
            name: .terminalTabSidebarItemDidChange,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onScrollBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)
        center.addObserver(
            self,
            selector: #selector(onClipViewFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: scrollView.contentView)
        center.addObserver(
            self,
            selector: #selector(onWindowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: nil)
    }

    override func layout() {
        super.layout()
        syncColumnWidth()
    }

    @objc private func onClipViewFrameDidChange(_ notification: Notification) {
        syncColumnWidth()
    }

    /// Makes the single column exactly as wide as the visible area of the table. A
    /// table column doesn't reliably follow the width of a programmatically created
    /// table, which put the trailing accessories (e.g. the close button) in the middle
    /// of the row or beyond its visible edge.
    private func syncColumnWidth() {
        guard let column = tableView.tableColumns.first else { return }
        let width = max(0, scrollView.contentView.bounds.width - tableView.intercellSpacing.width)
        guard abs(column.width - width) > 0.5 else { return }
        column.width = width
    }

    // MARK: Appearance

    /// Updates the sidebar background so it matches the terminal background.
    func updateAppearance(backgroundColor: NSColor) {
        let base = backgroundColor.usingColorSpace(.sRGB) ?? backgroundColor
        let isLight = base.isLightColor
        let tint: NSColor = isLight ? .black : .white
        let blended = base.withAlphaComponent(1).blended(withFraction: 0.06, of: tint) ?? base
        sidebarBackgroundColor = blended.withAlphaComponent(base.alphaComponent)

        // Use system label colors that are readable on top of our background.
        appearance = NSAppearance(named: isLight ? .aqua : .darkAqua)
        needsDisplay = true
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        sidebarBackgroundColor.setFill()
        bounds.fill()

        // A hairline separating the sidebar from the terminal.
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
    }

    // MARK: Structure

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        guard window != nil else {
            windowsObservation?.invalidate()
            windowsObservation = nil
            observedTabGroup = nil
            return
        }

        reloadStructure()
    }

    /// Rebuilds the list of tabs from the tab group.
    ///
    /// Accessing `tabGroup` on a window that was never shown materializes AppKit's tab
    /// machinery which is slow (~15-20ms), so we only do it once the window has been
    /// visible unless the caller knows the window already belongs to a tab group. Note
    /// that background tabs are ordered out, so we must remember this.
    func reloadStructure(includingTabGroup: Bool = false) {
        guard let hostWindow = window else { return }

        if includingTabGroup || hostWindow.isVisible { canAccessTabGroup = true }
        let useTabGroup = canAccessTabGroup
        let windows: [NSWindow] = useTabGroup ? (hostWindow.tabbedWindows ?? [hostWindow]) : [hostWindow]
        let controllers = windows.compactMap { $0.windowController as? TerminalController }

        let oldIdentities = tabs.map { $0.value.map(ObjectIdentifier.init) }
        let newIdentities = controllers.map { Optional(ObjectIdentifier($0)) }
        if oldIdentities == newIdentities {
            reconfigureVisibleRows()
        } else {
            finishEditing(commit: true)
            tabs = controllers.map { Weak($0) }
            tableView.reloadData()

            if let current = tabs.firstIndex(where: { $0.value === controller }) {
                tableView.scrollRowToVisible(current)
            }
        }

        if useTabGroup {
            rebindTabGroupIfNeeded()
        }
    }

    /// Observe the tab group of our window. The group can change (e.g. "Move Tab to
    /// New Window") so we check every time we reload.
    private func rebindTabGroupIfNeeded() {
        // Never replace a KVO observation from within its own callback.
        DispatchQueue.main.async { [weak self] in
            guard let self, let hostWindow = self.window else { return }
            let tabGroup = hostWindow.tabGroup
            guard tabGroup !== self.observedTabGroup || self.windowsObservation == nil else { return }

            self.windowsObservation?.invalidate()
            self.windowsObservation = nil
            self.observedTabGroup = tabGroup
            guard let tabGroup else { return }

            self.windowsObservation = tabGroup.observe(\.windows, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.reloadStructure()
                }
            }
        }
    }

    private func scheduleContentReload() {
        guard !pendingContentReload else { return }
        pendingContentReload = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingContentReload = false
            self.reconfigureVisibleRows()
        }
    }

    private func reconfigureVisibleRows() {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.location..<(visible.location + visible.length) {
            configure(row: row)
        }
    }

    private func configure(row: Int) {
        guard let tab = tabs[safe: row]?.value else { return }
        let content = TabSidebarRowContent(controller: tab, index: row, isCurrent: tab === controller)

        let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? TabSidebarRowView
        rowView?.content = content

        if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabSidebarCellView {
            configure(cell: cell, tab: tab, content: content, hovered: rowView?.isHovered ?? false)
        }
    }

    private func configure(
        cell: TabSidebarCellView,
        tab: TerminalController,
        content: TabSidebarRowContent,
        hovered: Bool
    ) {
        cell.isEditingTitle = editingController === tab && editingField === cell.titleField
        cell.configure(with: content)
        cell.isHovered = hovered
        cell.onClose = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.closeTab(tab)
        }
        cell.onResetZoom = { [weak tab] in
            guard let tab else { return }
            tab.splitZoom(tab)
        }
    }

    // MARK: Notifications

    @objc private func onNeedsReload(_ notification: Notification) {
        guard window != nil else { return }
        reloadStructure()
    }

    @objc private func onItemDidChange(_ notification: Notification) {
        guard window != nil else { return }
        guard let changed = notification.object as? TerminalController else { return }
        guard tabs.contains(where: { $0.value === changed }) else { return }
        scheduleContentReload()
    }

    /// Keep the scroll position of all sidebars in the tab group identical so switching
    /// tabs doesn't make the list jump.
    @objc private func onScrollBoundsDidChange(_ notification: Notification) {
        guard !Self.isSyncingScroll, window?.isKeyWindow ?? false else { return }
        Self.isSyncingScroll = true
        defer { Self.isSyncingScroll = false }

        let origin = scrollView.contentView.bounds.origin
        for tab in tabs {
            guard let other = tab.value, other !== controller,
                  let sidebar = other.terminalViewContainer?.tabSidebar else { continue }
            sidebar.scrollView.contentView.scroll(to: origin)
            sidebar.scrollView.reflectScrolledClipView(sidebar.scrollView.contentView)
        }
    }

    // MARK: Actions

    @objc private func newTabClicked(_ sender: Any?) {
        controller?.newTab(sender)
    }

    @objc private func rowClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard let target = tabs[safe: row]?.value else { return }
        let now = ProcessInfo.processInfo.systemUptime

        // Clicking the current tab: if this is the second click of a double click
        // that started in another tab's sidebar, start renaming.
        if target === controller {
            if let last = Self.lastSwitchClick,
               last.tab == ObjectIdentifier(target),
               now - last.time <= NSEvent.doubleClickInterval {
                Self.lastSwitchClick = nil
                beginRename(for: target)
                return
            }

            restoreTerminalFocus()
            return
        }

        Self.lastSwitchClick = (ObjectIdentifier(target), now)
        target.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard let target = tabs[safe: row]?.value else { return }
        Self.lastSwitchClick = nil

        // The double click may come in before the window switch completes.
        if target !== controller {
            target.window?.makeKeyAndOrderFront(nil)
            target.terminalViewContainer?.tabSidebar?.beginRename(for: target)
            return
        }

        beginRename(for: target)
    }

    /// Close a tab, confirming if necessary. The confirmation sheet is attached to the
    /// target's own window so we have to select it first.
    private func closeTab(_ target: TerminalController) {
        if target !== controller, target.surfaceTree.contains(where: { $0.needsConfirmQuit }) {
            target.window?.makeKeyAndOrderFront(nil)
        }

        target.closeTab(nil)
    }

    private func restoreTerminalFocus() {
        guard let window, window.isKeyWindow,
              let focusedSurface = controller?.focusedSurface else { return }
        window.makeFirstResponder(focusedSurface)
    }

    /// Called when the shared sidebar visibility hides this sidebar.
    func sidebarDidHide() {
        finishEditing(commit: true)
    }

    @objc private func onWindowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        finishEditing(commit: true, restoreFocus: false)
    }

    // MARK: Inline Rename

    /// Starts inline editing of the title of the given tab. Returns false if the
    /// sidebar can't edit it (e.g. the sidebar is hidden).
    @discardableResult
    func beginRename(for target: TerminalController) -> Bool {
        guard TabSidebarSettings.shared.isVisible, !isHidden,
              let window, window.isVisible else { return false }

        // Make sure our list is current, the target may have just been created.
        reloadStructure()
        guard let row = tabs.firstIndex(where: { $0.value === target }) else { return false }

        // Already editing this tab.
        if editingController === target, editingField != nil { return true }
        finishEditing(commit: true)

        tableView.scrollRowToVisible(row)
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? TabSidebarCellView else {
            return false
        }

        let field = cell.titleField
        editingController = target
        editingField = field
        cell.isEditingTitle = true

        field.stringValue = target.titleOverride ?? target.window?.title ?? ""
        field.isEditable = true
        field.isSelectable = true
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.textColor = .labelColor
        field.focusRingType = .none
        field.lineBreakMode = .byClipping
        field.cell?.truncatesLastVisibleLine = false
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self

        // Sidebar buttons don't take focus, so blur notifications alone don't
        // commit every click outside the editor. Preserve the click's normal action.
        editingClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak field] event in
            guard let self, let field else { return event }
            if event.window === field.window,
               field.bounds.contains(field.convert(event.locationInWindow, from: nil)) {
                return event
            }
            self.finishEditing(commit: true, restoreFocus: false)
            return event
        }

        window.makeFirstResponder(field)
        DispatchQueue.main.async { [weak field] in
            field?.currentEditor()?.selectAll(nil)
        }

        return true
    }

    /// Ends inline editing, optionally committing the new title.
    func finishEditing(commit: Bool, restoreFocus: Bool = true) {
        guard !isFinishingEdit, let field = editingField else { return }
        isFinishingEdit = true
        defer { isFinishingEdit = false }

        let target = editingController
        let text = field.currentEditor()?.string ?? field.stringValue
        editingController = nil
        editingField = nil
        if let editingClickMonitor {
            NSEvent.removeMonitor(editingClickMonitor)
            self.editingClickMonitor = nil
        }

        field.delegate = nil
        field.abortEditing()
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        field.cell?.isScrollable = false
        var ancestor = field.superview
        while let view = ancestor, !(view is TabSidebarCellView) { ancestor = view.superview }
        (ancestor as? TabSidebarCellView)?.isEditingTitle = false

        if commit, let target {
            target.titleOverride = text.isEmpty ? nil : text
        }

        reconfigureVisibleRows()
        if restoreFocus { restoreTerminalFocus() }
    }
}

// MARK: NSTextFieldDelegate

extension TabSidebarView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            finishEditing(commit: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            finishEditing(commit: false)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        let cancelled = obj.userInfo?[NSText.movementUserInfoKey] as? Int == NSTextMovement.cancel.rawValue
        finishEditing(commit: !cancelled, restoreFocus: cancelled)
    }
}

// MARK: NSTableViewDataSource / NSTableViewDelegate

extension TabSidebarView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tabs.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = TabSidebarRowView()
        if let tab = tabs[safe: row]?.value {
            rowView.content = TabSidebarRowContent(controller: tab, index: row, isCurrent: tab === controller)
        }
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tab = tabs[safe: row]?.value else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("TabSidebarCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? TabSidebarCellView
            ?? TabSidebarCellView(frame: .zero)
        cell.identifier = identifier

        let content = TabSidebarRowContent(controller: tab, index: row, isCurrent: tab === controller)
        let hovered = (tableView.rowView(atRow: row, makeIfNecessary: false) as? TabSidebarRowView)?.isHovered ?? false
        configure(cell: cell, tab: tab, content: content, hovered: hovered)
        return cell
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        (rowView as? TabSidebarRowView)?.syncHoverWithMouseLocation()
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        // We never use table selection, the current tab is highlighted by the row view.
        false
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard editingField == nil else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: .ghosttyTabSidebarRow)
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        // Only reorder within this sidebar.
        guard (info.draggingSource as? NSTableView) === tableView else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let value = info.draggingPasteboard.pasteboardItems?.first?.string(forType: .ghosttyTabSidebarRow),
              let source = Int(value),
              let destination = TabSidebarLogic.destinationIndex(from: source, dropRow: row, count: tabs.count),
              let tabWindow = tabs[safe: source]?.value?.window else { return false }

        TerminalController.moveTab(tabWindow, to: destination)
        reloadStructure()
        return true
    }
}

// MARK: Context Menu

extension TabSidebarView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let target = tabs[safe: tableView.clickedRow]?.value else { return }
        let isLast = tabs.last?.value === target

        func item(_ title: String, _ action: Selector, symbol: String, enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            item.target = self
            item.representedObject = Weak(target)
            item.isEnabled = enabled
            item.setImageIfDesired(systemSymbolName: symbol)
            return item
        }

        menu.autoenablesItems = false
        menu.addItem(item("Copy Title", #selector(copyTitle(_:)), symbol: "doc.on.doc"))
        menu.addItem(item(
            "Copy Working Directory",
            #selector(copyWorkingDirectory(_:)),
            symbol: "folder",
            enabled: !(target.focusedSurface?.pwd ?? "").isEmpty))
        menu.addItem(.separator())
        menu.addItem(item("Rename Tab...", #selector(renameTab(_:)), symbol: "pencil.line"))
        menu.addItem(.separator())
        menu.addItem(item("Close Tab", #selector(closeTabFromMenu(_:)), symbol: "xmark"))
        menu.addItem(item(
            "Close Other Tabs",
            #selector(closeOtherTabs(_:)),
            symbol: "xmark",
            enabled: tabs.count > 1))
        menu.addItem(item(
            "Close Tabs to the Right",
            #selector(closeTabsToTheRight(_:)),
            symbol: "xmark",
            enabled: !isLast))
        menu.addItem(.separator())

        let tabWindow = target.window as? TerminalWindow
        menu.addItem(TabColorMenuView.makeMenuItem(selectedColor: tabWindow?.tabColor ?? .none) { [weak tabWindow] color in
            tabWindow?.tabColor = color
        })
    }

    private func menuTarget(_ sender: Any?) -> TerminalController? {
        ((sender as? NSMenuItem)?.representedObject as? Weak<TerminalController>)?.value
    }

    @objc private func copyTitle(_ sender: Any?) {
        guard let target = menuTarget(sender) else { return }

        // We prefer the raw titles so we don't copy the bell prefix.
        let title = target.titleOverride ?? target.focusedSurface?.title ?? target.window?.title ?? ""
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(title, forType: .string)
    }

    @objc private func copyWorkingDirectory(_ sender: Any?) {
        guard let pwd = menuTarget(sender)?.focusedSurface?.pwd, !pwd.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(pwd, forType: .string)
    }

    @objc private func renameTab(_ sender: Any?) {
        guard let target = menuTarget(sender) else { return }

        // The menu is closing so we wait a tick for focus to settle.
        DispatchQueue.main.async { [weak self, weak target] in
            guard let self, let target else { return }
            if !self.beginRename(for: target) {
                target.promptTabTitle()
            }
        }
    }

    @objc private func closeTabFromMenu(_ sender: Any?) {
        guard let target = menuTarget(sender) else { return }
        closeTab(target)
    }

    @objc private func closeOtherTabs(_ sender: Any?) {
        guard let target = menuTarget(sender) else { return }
        if target !== controller { target.window?.makeKeyAndOrderFront(nil) }
        target.closeOtherTabs(nil)
    }

    @objc private func closeTabsToTheRight(_ sender: Any?) {
        guard let target = menuTarget(sender) else { return }
        if target !== controller { target.window?.makeKeyAndOrderFront(nil) }
        target.closeTabsOnTheRight(nil)
    }
}

// MARK: Subviews

/// The table view in the sidebar. It never takes focus away from the terminal.
final class TabSidebarTableView: NSTableView {
    override var acceptsFirstResponder: Bool { false }
}

/// The header at the top of the sidebar. It holds the new tab button and acts as a
/// window drag area (important for `macos-titlebar-style = hidden`).
final class TabSidebarHeaderView: NSView {
    let newTabButton: NSButton = {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.refusesFirstResponder = true
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "New Tab"
        button.setAccessibilityIdentifier("TabSidebarNewTabButton")
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(newTabButton)
        NSLayoutConstraint.activate([
            newTabButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            newTabButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            newTabButton.widthAnchor.constraint(equalToConstant: 20),
            newTabButton.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.performZoom(nil)
            return
        }

        window?.performDrag(with: event)
    }
}
