import AppKit
import Combine
import SwiftUI

/// AppKit presentation over the existing native-window tab model.
/// Stable nodes keep selection-only updates from rebuilding the outline.
struct NativeTabOutlineConfiguration {
    let groups: [GhosttyTabGroupPresentation]
    let selectedID: ObjectIdentifier?
    let layoutState: VerticalTabWindowLayoutState
    let controller: TerminalController
    let rowHeight: CGFloat
    let presentation: (GhosttyOrganizedTab) -> GhosttyTabPresentation?

}

@MainActor
final class NativeTabNode: NSObject {
    let key: String
    var title: String?
    var icon: GhosttyTabIcon?
    var tab: GhosttyOrganizedTab?
    var children: [NativeTabNode] = []
    init(key: String) { self.key = key }
}

@MainActor
final class NativeTabOutlineController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    static let tabType = NSPasteboard.PasteboardType("com.jischeng.omg.native-sidebar-tab")
    let outline: NativeTabOutline
    let scrollView = NSScrollView()
    var configuration: NativeTabOutlineConfiguration
    var roots: [NativeTabNode] = []
    var nodes: [String: NativeTabNode] = [:]
    var structure: [String] = []
    var updating = false
    var lastSelectedID: ObjectIdentifier?
    private var selectionChangeGeneration = 0
    private(set) var reloadCount = 0
    private(set) var moveCount = 0
    private(set) var membershipUpdateCount = 0

    /// Insert/delete without reloading existing cells when survivor order is
    /// unchanged (the normal new-tab/close-tab path).
    private func updateMembership(from old: [String], to new: [String], parent: NativeTabNode?) -> Bool {
        guard old != new else { return true }
        let oldSet = Set(old)
        let newSet = Set(new)
        guard old.filter(newSet.contains) == new.filter(oldSet.contains) else { return false }
        let removed = IndexSet(old.indices.filter { !newSet.contains(old[$0]) })
        let inserted = IndexSet(new.indices.filter { !oldSet.contains(new[$0]) })
        guard !removed.isEmpty || !inserted.isEmpty else { return false }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            outline.beginUpdates()
            if !removed.isEmpty { outline.removeItems(at: removed, inParent: parent, withAnimation: []) }
            if !inserted.isEmpty { outline.insertItems(at: inserted, inParent: parent, withAnimation: []) }
            outline.endUpdates()
        }
        membershipUpdateCount += 1
        return true
    }

    /// Recognize one drag move in either direction, rather than shifting all
    /// intervening rows. AppKit owns the row movement and selection tracking.
    static func singleMove(from old: [String], to new: [String]) -> (Int, Int)? {
        guard old.count == new.count, Set(old) == Set(new), old != new,
              let first = old.indices.first(where: { old[$0] != new[$0] }) else { return nil }
        for source in [first, old.firstIndex(of: new[first])].compactMap({ $0 }) {
            guard let destination = new.firstIndex(of: old[source]) else { continue }
            var candidate = old
            candidate.insert(candidate.remove(at: source), at: destination)
            if candidate == new { return (source, destination) }
        }
        return nil
    }

    init(_ parent: NativeTabOutlineConfiguration) {
        self.configuration = parent
        outline = NativeTabOutline()
        super.init(nibName: nil, bundle: nil)
        outline.activateSelectedRow = { [weak self] in self?.activateSelectedRow() }
        outline.didBeginMouseTracking = { [weak self] in self?.selectionChangeGeneration += 1 }
        outline.didBeginDrag = { [weak self] in self?.selectionChangeGeneration += 1 }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let scroll = scrollView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        let column = NSTableColumn(identifier: .init("tab"))
        column.resizingMask = .autoresizingMask
        outline.autoresizingMask = [.width]
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.backgroundColor = .clear
        // Source-list style installs a system material behind the terminal's
        // transparent theme. Keep native table interaction without that material.
        outline.style = .plain
        outline.selectionHighlightStyle = .regular
        outline.floatsGroupRows = false
        outline.rowSizeStyle = .custom
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.allowsEmptySelection = false
        outline.allowsMultipleSelection = false
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(activateClickedRow)
        outline.registerForDraggedTypes([Self.tabType, .ghosttySurfaceId])
        outline.contextMenu = { [weak self] row in self?.menu(for: row) }
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setAccessibilityLabel("Tabs")
        scroll.documentView = outline
        view = scroll
    }

    private func activateSelectedRow() {
        activate(row: outline.selectedRow)
    }

    @objc private func activateClickedRow() {
        guard let item = outline.item(atRow: outline.clickedRow) as? NativeTabNode else { return }
        let generation = selectionChangeGeneration
        DispatchQueue.main.async { [weak self, weak item] in
            guard let self, self.selectionChangeGeneration == generation,
                  let item,
                  !self.outline.isDraggingTab else { return }
            self.activate(row: self.outline.row(forItem: item))
        }
    }

    private func activate(row: Int) {
        guard row >= 0, let item = outline.item(atRow: row) as? NativeTabNode,
              let tab = item.tab else { return }
        let controller = tab.controller
        selectionChangeGeneration += 1
        lastSelectedID = tab.id
        controller.selectVerticalTab(controller)
        if let surface = controller.focusedSurface ?? controller.surfaceTree.first {
            Ghostty.moveFocus(to: surface)
        }
    }

    func update(_ value: NativeTabOutlineConfiguration) {
        configuration = value
        updating = true
        defer { updating = false }
        let oldRoots = roots.map(\.key)
        let oldChildren = Dictionary(uniqueKeysWithValues: roots.filter { $0.tab == nil }.map {
            ($0.key, $0.children.map(\.key))
        })
        var nextNodes: [String: NativeTabNode] = [:]
        var nextRoots: [NativeTabNode] = []
        var nextStructure: [String] = []
        func node(_ key: String) -> NativeTabNode {
            let result = nodes[key] ?? NativeTabNode(key: key)
            nextNodes[key] = result
            return result
        }
        for group in value.groups {
            let children = group.tabs.map { tab -> NativeTabNode in
                let item = node("tab:\(tab.controller.tabSessionID)")
                item.tab = tab
                nextStructure.append("\(group.id)/\(item.key)")
                return item
            }
            if let title = group.title {
                let item = node("group:\(group.id)")
                item.title = title
                item.icon = group.icon
                item.children = children
                nextRoots.append(item)
                nextStructure.append(item.key)
            } else {
                nextRoots.append(contentsOf: children)
            }
        }
        roots = nextRoots
        nodes = nextNodes
        outline.rowHeight = value.rowHeight
        if structure != nextStructure {
            structure = nextStructure
            let newRoots = roots.map(\.key)
            let changedGroups = roots.filter {
                $0.tab == nil && oldChildren[$0.key] != $0.children.map(\.key)
            }
            if oldChildren.isEmpty, roots.allSatisfy({ $0.tab != nil }),
               let (source, destination) = Self.singleMove(from: oldRoots, to: newRoots) {
                outline.moveItem(at: source, inParent: nil, to: destination, inParent: nil)
                moveCount += 1
            } else if oldRoots == newRoots, changedGroups.count == 1,
                      let group = changedGroups.first, let old = oldChildren[group.key],
                      let (source, destination) = Self.singleMove(from: old, to: group.children.map(\.key)) {
                outline.moveItem(at: source, inParent: group, to: destination, inParent: group)
                moveCount += 1
            } else if oldChildren.isEmpty, roots.allSatisfy({ $0.tab != nil }),
                      updateMembership(from: oldRoots, to: newRoots, parent: nil) {
                // Native insertion/removal preserves existing row views.
            } else if oldRoots == newRoots, changedGroups.count == 1,
                      let group = changedGroups.first, let old = oldChildren[group.key],
                      updateMembership(from: old, to: group.children.map(\.key), parent: group) {
                // Same operation inside an existing project/date group.
            } else {
                outline.reloadData()
                reloadCount += 1
            }
        }
        for group in value.groups where group.title != nil {
            guard let item = nodes["group:\(group.id)"] else { continue }
            let selected = group.tabs.contains { ObjectIdentifier($0.controller) == value.selectedID }
            if !value.layoutState.collapsedGroupIDs.contains(group.id) || selected {
                outline.expandItem(item)
            } else {
                outline.collapseItem(item)
            }
        }
        if let selected = nodes.values.first(where: {
            $0.tab.map { ObjectIdentifier($0.controller) == value.selectedID } ?? false
        }) {
            let row = outline.row(forItem: selected)
            if row >= 0 {
                if outline.selectedRow != row {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
                let rowRect = outline.rect(ofRow: row)
                let outsideViewport = rowRect.minY < outline.visibleRect.minY ||
                    rowRect.maxY > outline.visibleRect.maxY
                if lastSelectedID != value.selectedID, outsideViewport,
                   !value.layoutState.sidebarHost.restorePendingScrollPosition() {
                    outline.scrollRowToVisible(row)
                }
            }
        }
        lastSelectedID = value.selectedID
        outline.enumerateAvailableRowViews { row, _ in row.needsDisplay = true }
        // Update only instantiated cells; offscreen rows are configured on demand.
        let visible = outline.rows(in: outline.visibleRect)
        if visible.location != NSNotFound {
            for row in visible.location..<NSMaxRange(visible) {
                guard let item = outline.item(atRow: row) as? NativeTabNode,
                      let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? NativeTabCell else {
                    continue
                }
                configure(cell, item: item)
            }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? NativeTabNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? NativeTabNode)?.children ?? roots)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? NativeTabNode)?.tab == nil
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { NativeTabRowView() }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? NativeTabNode)?.tab != nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? NativeTabNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("native-tab-cell")
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? NativeTabCell) ?? NativeTabCell()
        cell.identifier = identifier
        configure(cell, item: item)
        return cell
    }

    private func configure(_ cell: NativeTabCell, item: NativeTabNode) {
        cell.configure(tab: item.tab, title: item.title, presentation: configuration.presentation,
                       groupIcon: item.icon,
                       canClose: configuration.groups.reduce(0) { $0 + $1.tabs.count } > 1,
                       selected: item.tab?.id == configuration.selectedID,
                       select: { [weak self, weak item] in
            guard let self, let item else { return }
            self.activate(row: self.outline.row(forItem: item))
        }, close: { [weak self, weak item] in
            guard let self, let tab = item?.tab else { return }
            self.configuration.controller.closeVerticalTab(tab.controller)
        })
    }

    private func menu(for row: Int) -> NSMenu? {
        guard let tab = (outline.item(atRow: row) as? NativeTabNode)?.tab?.controller else { return nil }
        return NativeActionMenu.make([
            .action("New Tab", symbol: "plus") { [weak tab] in tab?.newVerticalTab() },
            .action("Rename Tab…", symbol: "pencil") { [weak tab] in tab?.promptTabTitle() },
            .separator,
            .action("Move Tab to New Window", symbol: "macwindow",
                    enabled: (tab.window?.tabGroup?.windows.count ?? 1) > 1) { [weak tab] in
                guard let window = tab?.window else { return }
                NSApp.sendAction(NSSelectorFromString("moveTabToNewWindow:"), to: window, from: nil)
            },
            .action("Close Other Tabs", enabled: configuration.controller.tabControllers.count > 1) { [weak tab] in
                tab?.closeOtherTabs(nil)
            },
            .action("Close Tab", symbol: "xmark") { [weak tab] in tab?.closeTab(nil) },
        ])
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !updating, let item = outline.item(atRow: outline.selectedRow) as? NativeTabNode,
              let tab = item.tab else { return }
        // AppKit sends selection notifications inside mouseDown tracking.
        // The completed click path activates after super.mouseDown returns;
        // drag selection must never reparent the host during its preview.
        guard outline.isNavigatingWithKeyboard, !outline.isDraggingTab else { return }
        // Keyboard row changes select the matching native tab after AppKit
        // finishes dispatching the selection notification.
        let id = tab.id
        let generation = selectionChangeGeneration
        // A clicked row is already visible. Do not scroll again when native
        // window selection feeds back through the presentation snapshot.
        lastSelectedID = id
        DispatchQueue.main.async { [weak self, weak item] in
            guard let self, self.selectionChangeGeneration == generation,
                  let tab = item?.tab,
                  let selected = self.outline.item(atRow: self.outline.selectedRow) as? NativeTabNode,
                  selected.tab?.id == id else { return }
            self.configuration.controller.selectVerticalTab(tab.controller)
            self.outline.window?.makeFirstResponder(self.outline)
            // Native tab activation also schedules terminal focus repair.
            // Finish keyboard navigation after that handoff, unless a newer
            // pointer/activation gesture or tab selection superseded it.
            DispatchQueue.main.async { [weak self, weak item] in
                guard let self, self.selectionChangeGeneration == generation,
                      let tab = item?.tab, let window = self.outline.window,
                      window === tab.controller.window, window.isKeyWindow,
                      (self.outline.item(atRow: self.outline.selectedRow) as? NativeTabNode)?.tab?.id == id else { return }
                window.makeFirstResponder(self.outline)
            }
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) { saveExpansion(notification, collapsed: false) }
    func outlineViewItemDidCollapse(_ notification: Notification) { saveExpansion(notification, collapsed: true) }

    private func saveExpansion(_ notification: Notification, collapsed: Bool) {
        guard !updating, let node = notification.userInfo?["NSObject"] as? NativeTabNode else { return }
        let id = String(node.key.dropFirst("group:".count))
        DispatchQueue.main.async { [weak self] in
            guard let self, self.configuration.layoutState.collapsedGroupIDs.contains(id) != collapsed else { return }
            self.configuration.layoutState.toggleGroup(id)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let tab = (item as? NativeTabNode)?.tab else { return nil }
        let writer = NSPasteboardItem()
        writer.setString(tab.controller.tabSessionID.uuidString, forType: Self.tabType)
        return writer
    }

    private func drop(_ info: NSDraggingInfo, item: Any?, index: Int) -> (TerminalController, Int)? {
        guard let sourceView = info.draggingSource as? NSOutlineView, sourceView === outline,
              let raw = info.draggingPasteboard.string(forType: Self.tabType),
              let id = UUID(uuidString: raw) else { return nil }
        return resolveDrop(sourceID: id, item: item, index: index)
    }

    private func destination(item: Any?, index: Int) -> (TerminalController, VerticalTabDropPolicy.Placement)? {
        if index == NSOutlineViewDropOnItemIndex, let tab = (item as? NativeTabNode)?.tab {
            return (tab.controller, .after)
        }
        if index == NSOutlineViewDropOnItemIndex, let tab = (item as? NativeTabNode)?.children.last?.tab {
            return (tab.controller, .after)
        }
        let children = (item as? NativeTabNode)?.children ?? roots
        guard index >= 0, index <= children.count else { return nil }
        if index < children.count, let tab = children[index].tab ?? children[index].children.first?.tab {
            return (tab.controller, .before)
        }
        guard let tab = children.last?.tab ?? children.last?.children.last?.tab else { return nil }
        return (tab.controller, .after)
    }

    private func externalTab(_ info: NSDraggingInfo) -> TerminalController? {
        guard let source = info.draggingSource as? NativeTabOutline, source !== outline,
              let raw = info.draggingPasteboard.string(forType: Self.tabType), let id = UUID(uuidString: raw) else { return nil }
        return configuration.controller.workspaceCoordinator.liveControllers.first {
            $0.tabSessionID == id && $0.workspaceID == configuration.controller.workspaceID && $0.isAvailableForWorkspace
        }
    }

    private func surface(_ info: NSDraggingInfo) -> Ghostty.SurfaceView? {
        guard info.draggingSource != nil,
              let data = info.draggingPasteboard.data(forType: .ghosttySurfaceId), data.count == 16 else { return nil }
        return Ghostty.SurfaceView.find(uuid: data.withUnsafeBytes { $0.loadUnaligned(as: UUID.self) })
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        outline.dragBegan()
        configuration.controller.beginManualTabDrag()
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Drag selection is only AppKit feedback. On cancellation as well as
        // success, restore the row corresponding to the actual selected tab.
        update(configuration)
        outline.dragEnded()
    }

    func resolveDrop(sourceID id: UUID, item: Any?, index: Int) -> (TerminalController, Int)? {
        guard index >= 0,
              let group = configuration.groups.first(where: { $0.tabs.contains { $0.controller.tabSessionID == id } }),
              let source = group.tabs.first(where: { $0.controller.tabSessionID == id }) else { return nil }
        let children: [NativeTabNode]
        if let item = item as? NativeTabNode {
            guard item.key == "group:\(group.id)" else { return nil }
            children = item.children
        } else {
            guard group.title == nil else { return nil }
            children = roots
        }
        guard index <= children.count,
              let windows = configuration.controller.window?.tabGroup?.windows,
              let sourceWindow = source.controller.window,
              windows.contains(sourceWindow) else { return nil }
        // Presentation indexes are one-based shortcut labels. Resolve the
        // stable target against the current native order at validation/commit.
        let target = index < children.count ? children[index] : children.last
        guard let targetWindow = target?.tab?.controller.window,
              let targetIndex = windows.firstIndex(of: targetWindow) else { return nil }
        return (source.controller, targetIndex + (index == children.count ? 1 : 0))
    }

    func insertionProposal(item: Any?, index: Int, point: NSPoint) -> (NativeTabNode?, Int) {
        guard index == NSOutlineViewDropOnItemIndex else { return (item as? NativeTabNode, index) }
        guard let node = item as? NativeTabNode else { return (nil, roots.count) }
        guard node.tab != nil else { return (node, node.children.count) }
        let parent = outline.parent(forItem: node) as? NativeTabNode
        let children = parent?.children ?? roots
        guard let childIndex = children.firstIndex(where: { $0 === node }) else { return (parent, -1) }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return (parent, -1) }
        return (parent, childIndex + (point.y < outline.rect(ofRow: row).midY ? 0 : 1))
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let (item, index) = insertionProposal(item: item, index: index, point: outline.convert(info.draggingLocation, from: nil))
        outline.setDropItem(item, dropChildIndex: index)
        if drop(info, item: item, index: index) != nil { return .move }
        guard destination(item: item, index: index) != nil else { return [] }
        if let source = externalTab(info), !source.sharesNativeTabGroup(with: configuration.controller) { return .move }
        if let surface = surface(info),
           let owner = BaseTerminalController.controller(owning: surface) as? TerminalController,
           owner.workspaceID == configuration.controller.workspaceID,
           owner.surfaceTree.isSplit || !owner.sharesNativeTabGroup(with: configuration.controller) { return .move }
        return []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        let (item, index) = insertionProposal(item: item, index: index, point: outline.convert(info.draggingLocation, from: nil))
        guard let (source, insertion) = drop(info, item: item, index: index) else {
            guard let (target, placement) = destination(item: item, index: index) else { return false }
            if let source = externalTab(info) {
                return configuration.controller.attachNativeTab(source, relativeTo: target, placement: placement)
            }
            if let surface = surface(info),
               let owner = BaseTerminalController.controller(owning: surface) as? TerminalController,
               owner.workspaceID == configuration.controller.workspaceID {
                return configuration.controller.moveSurfaceToNewTab(surface, relativeTo: target, placement: placement)
            }
            return false
        }
        let committed = configuration.controller.reorderTab(source, toInsertionIndex: insertion)
        if committed {
            // Publish the native order before CoreDrag finishes its preview;
            // waiting for SwiftUI's next update produces an old-order frame.
            let groups = GhosttyTabOrganizationModel().groups(
                tabs: configuration.controller.tabControllers,
                grouping: configuration.layoutState.groupingMode,
                ordering: configuration.layoutState.orderingMode
            )
            update(NativeTabOutlineConfiguration(
                groups: groups, selectedID: configuration.layoutState.tabSnapshot.selectedID,
                layoutState: configuration.layoutState, controller: configuration.controller,
                rowHeight: configuration.rowHeight, presentation: configuration.presentation
            ))
        }
        return committed
    }
}
/// Adds a deliberate terminal activation gesture while leaving row navigation
/// and drag tracking to AppKit.
@MainActor
final class NativeTabOutline: NSOutlineView {
    var activateSelectedRow: (() -> Void)?
    var didBeginMouseTracking: (() -> Void)?
    var didBeginDrag: (() -> Void)?
    private(set) var isNavigatingWithKeyboard = false
    private(set) var isDraggingTab = false
    private weak var mouseDownResponder: NSResponder?
    var contextMenu: ((Int) -> NSMenu?)?
    private lazy var hover = NativeTableHover(table: self)
    override func updateTrackingAreas() { super.updateTrackingAreas(); hover.update() }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?(row(at: convert(event.locationInWindow, from: nil))) }

    override func mouseDown(with event: NSEvent) {
        mouseDownResponder = window?.firstResponder
        didBeginMouseTracking?()
        super.mouseDown(with: event)
    }

    func dragBegan() {
        isDraggingTab = true
        didBeginDrag?()
    }

    func dragEnded() {
        isDraggingTab = false
        if let previous = mouseDownResponder as? NSView, previous.window === window {
            window?.makeFirstResponder(previous)
        }
        mouseDownResponder = nil
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            activateSelectedRow?()
            return
        }
        isNavigatingWithKeyboard = true
        defer { isNavigatingWithKeyboard = false }
        super.keyDown(with: event)
    }
}

private final class NativeTabRowView: NativeHoverRowView {
    override var isSelected: Bool {
        didSet {
            guard oldValue != isSelected, numberOfColumns > 0 else { return }
            (view(atColumn: 0) as? NativeTabCell)?.updateSelection(isSelected)
        }
    }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        OMGNativeTheme.resolve(for: self).selectedFill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}

/// AppKit cells observe their own title changes instead of invalidating the list.
@MainActor
final class NativeTabCell: NSTableCellView {
    private let icon = NativeTabIconView()
    private let label = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")
    private let status = NSImageView()
    private let closeButton = NativeActionControl()
    private var closeAction: (() -> Void)?
    private var observations = Set<AnyCancellable>()
    private var surfaceObservations = Set<AnyCancellable>()
    private var configuredTab: GhosttyOrganizedTab?
    private var presentation: ((GhosttyOrganizedTab) -> GhosttyTabPresentation?)?
    private var selected = false
    private var selectAction: (() -> Void)?
    private var refreshScheduled = false
    private var canClose = false
    private var hovering = false
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if tracking == nil {
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area)
            tracking = area
        }
        hovering = NativePointerLocation.contains(self)
        updateTrailing()
    }

    override func mouseEntered(with event: NSEvent) { hovering = NativePointerLocation.contains(self); updateTrailing() }
    override func mouseExited(with event: NSEvent) { hovering = false; updateTrailing() }

    func updateSelection(_ selected: Bool) {
        guard self.selected != selected else { return }
        self.selected = selected
        icon.updateSelection(selected)
    }

    private func updateTrailing() {
        closeButton.isHidden = !(hovering && canClose)
        shortcut.isHidden = hovering && canClose
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        closeButton.title = ""
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 13)
        shortcut.font = .systemFont(ofSize: 10)
        shortcut.textColor = .secondaryLabelColor
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        closeButton.setAccessibilityLabel("Close Tab")
        let trailing = NSView()
        for view in [shortcut, closeButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            trailing.addSubview(view)
            NSLayoutConstraint.activate([
                view.trailingAnchor.constraint(equalTo: trailing.trailingAnchor),
                view.centerYAnchor.constraint(equalTo: trailing.centerYAnchor)
            ])
        }
        trailing.widthAnchor.constraint(equalToConstant: 28).isActive = true
        trailing.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let stack = NSStackView(views: [icon, label, status, trailing])
        stack.distribution = .fill
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.init(1), for: .horizontal)
        // AppKit briefly sizes newly attached cells below their icon footprint.
        // Keep their content intact without unsatisfiable required constraints.
        let trailingConstraint = stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        trailingConstraint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            trailingConstraint,
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: TabIconMetrics.footprint),
            icon.heightAnchor.constraint(equalToConstant: TabIconMetrics.footprint),
            status.widthAnchor.constraint(equalToConstant: 14),
            status.heightAnchor.constraint(equalToConstant: 14),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20)
        ])
        // Do not register these as NSTableCellView's standard outlets: source
        // list cell layout can reposition them around our stack constraints.
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Row configuration keeps the native interaction callbacks explicit.
    // swiftlint:disable:next function_parameter_count
    func configure(tab: GhosttyOrganizedTab?, title: String?,
                   presentation: @escaping (GhosttyOrganizedTab) -> GhosttyTabPresentation?,
                   groupIcon: GhosttyTabIcon? = nil,
                   canClose: Bool, selected: Bool, select: @escaping () -> Void,
                   close: @escaping () -> Void) {
        let changedController = configuredTab?.controller !== tab?.controller
        if tab == nil || changedController {
            observations.removeAll()
            surfaceObservations.removeAll()
        }
        configuredTab = tab
        self.presentation = presentation
        self.selected = selected
        selectAction = select
        closeAction = close
        self.canClose = tab != nil && canClose
        updateTrailing()
        guard let tab else {
            configuredTab = nil
            self.presentation = nil
            selectAction = nil
            label.stringValue = title ?? ""
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            icon.configure(controller: nil, icon: groupIcon ?? .systemSymbol("folder"), selected: false, activity: nil)
            shortcut.stringValue = ""
            status.isHidden = true
            toolTip = nil
            setAccessibilityLabel(title ?? "")
            return
        }
        if changedController {
            observe(tab.controller)
        }
        refreshNow()
    }

    private func observe(_ controller: TerminalController) {
        // objectWillChange covers non-published presentation state such as the
        // title override and session context, alongside the published tree,
        // focus, and agent activity changes.
        controller.objectWillChange
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &observations)
        controller.$surfaceTree
            .sink { [weak self] tree in
                guard let self else { return }
                self.observeSurfaces(in: tree)
                self.scheduleRefresh()
            }
            .store(in: &observations)
    }

    private func observeSurfaces(in tree: SplitTree<Ghostty.SurfaceView>) {
        surfaceObservations.removeAll()
        for surface in tree {
            surface.$title.sink { [weak self] _ in self?.scheduleRefresh() }
                .store(in: &surfaceObservations)
            surface.$pwd.sink { [weak self] _ in self?.scheduleRefresh() }
                .store(in: &surfaceObservations)
        }
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refreshNow()
        }
    }

    private func refreshNow() {
        guard let tab = configuredTab, let presentation,
              let value = presentation(tab) else { return }
        let selected = self.selected
        label.font = .systemFont(ofSize: 13)
        label.stringValue = value.title
        shortcut.stringValue = value.shortcut ?? ""
        toolTip = value.remoteBreadcrumb?.title ?? value.title
        icon.configure(controller: tab.controller, icon: value.icon, selected: selected, activity: value.activity)
        label.stringValue = value.remoteBreadcrumb?.title ?? value.title
        let theme = OMGNativeTheme.resolve(for: self)
        label.textColor = theme.foreground
        shortcut.textColor = theme.secondary
        let symbol: String?
        switch value.activity?.state {
        case .needsAttention: symbol = "exclamationmark.circle.fill"
        case .error: symbol = "xmark.circle.fill"
        case .done: symbol = "checkmark.circle.fill"
        default: symbol = nil
        }
        status.isHidden = symbol == nil
        status.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        status.toolTip = value.activity?.state.rawValue
        setAccessibilityLabel(value.title)
    }

    @objc private func closeTab() { closeAction?() }
}
