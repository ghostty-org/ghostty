import AppKit
import SwiftUI

enum GitCollectionInteraction: Equatable { case changes, branches, picker, references }

final class GitCollectionController {
    var move: (Int) -> Void = { _ in }
    var activate: () -> Void = {}
}

final class GitCollectionTableView: GitHoverTableView {
    var moveSelection: (Int) -> Void = { _ in }
    var activateSelection: () -> Void = {}
    var cancel: () -> Void = {}
    var copySelection: () -> Void = {}
    var toggleStageSelection: (() -> Void)?
    var selectFromClick: ((Int, NSEvent.ModifierFlags, Int) -> Void)?
    private(set) var clickModifiers: NSEvent.ModifierFlags = []
    private(set) var selectionClickRow: Int?
    private var handledSelectionMouseDown = false
    override func mouseDown(with event: NSEvent) {
        handledSelectionMouseDown = false
        clickModifiers = event.modifierFlags.intersection([.command, .shift])
        selectionClickRow = row(at: convert(event.locationInWindow, from: nil))
        defer { clickModifiers = []; selectionClickRow = nil }
        if selectionClickRow == -1 { handledSelectionMouseDown = true; deselectAll(nil); clearHover(); return }
        if let row = selectionClickRow, let selectFromClick {
            let point = convert(event.locationInWindow, from: nil)
            let cell = view(atColumn: 0, row: row, makeIfNecessary: false)
            let controlHit = cell.map { cell in
                let local = cell.convert(point, from: self)
                return cell.subviews.contains { $0 is NSButton && !$0.isHidden && $0.frame.contains(local) }
            } ?? false
            if !controlHit {
                handledSelectionMouseDown = true
                window?.makeFirstResponder(self)
                selectFromClick(row, clickModifiers, event.clickCount)
                return
            }
        }
        super.mouseDown(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        if handledSelectionMouseDown { handledSelectionMouseDown = false; return }
        super.mouseUp(with: event)
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: moveSelection(-1)
        case 125: moveSelection(1)
        case 36, 76: activateSelection()
        case 49: if let toggleStageSelection { toggleStageSelection() } else { activateSelection() }
        case 53: cancel()
        default: super.keyDown(with: event)
        }
    }
    @objc func copy(_ sender: Any?) { copySelection() }
}

/// All three Git collections use the same reusable native cells and row diff.
struct GitCollectionView: NSViewRepresentable {
    var source: GitCollectionSource
    var mode: GitCollectionMode = .list
    var query = ""
    var languageCode = GitL10n.current.languageCode
    var pending: Set<String> = []
    var canWrite = true
    var interaction: GitCollectionInteraction = .changes
    var state: GitCollectionState?
    var stateKey = ""
    var selectedID: String?
    var extraRefs: [GitRefDecoration] = []
    var pasteboard = NSPasteboard.general
    var referenceAction: (GitRefDecoration) -> Void = { InspectorCopyMenu.copy($0.name) }
    var controller: GitCollectionController?
    var cancel: () -> Void = {}
    let perform: (InspectorGitAction) -> Void
    @Environment(\.gitCollectionColors) private var colors

    func makeCoordinator() -> Coordinator { Coordinator() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let table = GitCollectionTableView()
        table.style = .plain
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let column = NSTableColumn(identifier: .init("git-collection"))
        column.minWidth = 0
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.action = #selector(Coordinator.clicked)
        table.doubleAction = #selector(Coordinator.doubleClicked)
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
        table.setAccessibilityIdentifier(stateKey)
        scroll.documentView = table
        context.coordinator.table = table
        table.rowIdentity = { [weak coordinator = context.coordinator] index in
            guard let coordinator, coordinator.rows.indices.contains(index), coordinator.rows[index].item.isSelectable else { return nil }
            return coordinator.rows[index].id
        }
        context.coordinator.update(self)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update(self) }
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) { coordinator.saveAnchor() }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        weak var table: GitCollectionTableView?
        private(set) var rows: [GitCollectionRow] = []
        private var nodes: [GitCollectionNode] = []
        private var input: GitCollectionView?
        private var fallbackState = GitCollectionState()
        private var filterCollapsed = Set<String>()
        private var updating = false
        private var selectionAnchorID: String?
        private var state: GitCollectionState { input?.state ?? fallbackState }
        private var storageKey: String { (input?.stateKey ?? "") + "/" + (input?.mode.rawValue ?? "list") }

        func update(_ value: GitCollectionView) {
            let old = input
            let changedContext = old?.stateKey != value.stateKey
            let changedMode = old?.mode != value.mode
            let changedQuery = old?.query != value.query
            let rebuild = old?.source != value.source || changedMode || changedQuery || changedContext ||
                old?.pending != value.pending || old?.canWrite != value.canWrite || old?.extraRefs != value.extraRefs || old?.languageCode != value.languageCode
            if changedContext || changedMode { saveAnchor() }
            input = value
            guard let table else { return }
            table.allowsMultipleSelection = value.interaction == .changes
            table.pasteboard = value.pasteboard
            table.cancel = { [weak self] in
                if value.interaction == .changes { self?.clearSelection() }
                value.cancel()
            }
            table.toggleStageSelection = value.interaction == .changes ? { [weak self] in self?.toggleSelectedStage() } : nil
            table.selectFromClick = value.interaction == .changes ? { [weak self] row, modifiers, clicks in
                self?.select(row: row, modifiers: modifiers, clickCount: clicks)
            } : nil
            table.focusedKeyHandler = { [weak table] event in
                guard event.keyCode == 49, event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
                      let action = table?.toggleStageSelection else { return false }
                action(); return true
            }
            table.moveSelection = { [weak self] in self?.moveSelection($0) }
            table.activateSelection = { [weak self] in self?.activateSelected() }
            table.copySelection = { [weak self] in self?.copySelected() }
            table.copyValue = { [weak self] in self?.selectedCopyValue() }
            value.controller?.move = table.moveSelection
            value.controller?.activate = table.activateSelection
            if changedQuery { filterCollapsed.removeAll() }
            if rebuild {
                nodes = GitCollectionBuilder.nodes(source: value.source, mode: value.mode, query: value.query,
                                                   pending: value.pending, canWrite: value.canWrite, extraRefs: value.extraRefs)
                let collapsed = value.query.isEmpty ? state.collapsed[value.stateKey, default: []] : filterCollapsed
                let initial: String?
                if case .refs(let branches, _, _, _, _) = value.source { initial = branches.first(where: \.isCurrent)?.id } else { initial = nil }
                let selection = old == nil || changedContext || old?.selectedID != value.selectedID
                    ? value.selectedID ?? state.selected[value.stateKey] ?? initial
                    : state.selected[value.stateKey] ?? value.selectedID ?? initial
                apply(GitCollectionBuilder.rows(nodes, collapsed: collapsed), reset: changedContext || changedMode,
                      preferredSelection: selection)
                if value.interaction == .picker, old == nil || changedQuery, table.selectedRow >= 0 {
                    DispatchQueue.main.async { [weak self, weak table] in
                        guard let self, let table, self.input?.query == value.query, table.visibleRect.height > 0, table.selectedRow >= 0 else { return }
                        if table.selectedRow <= 1, let scroll = table.enclosingScrollView {
                            scroll.contentView.scroll(to: .zero)
                            scroll.reflectScrolledClipView(scroll.contentView)
                        } else { table.scrollRowToVisible(table.selectedRow) }
                    }
                }
            }
            if old?.colors != value.colors {
                table.enumerateAvailableRowViews { view, index in
                    (view as? GitCollectionRowView)?.colors = value.colors
                    if self.rows.indices.contains(index), let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? GitCollectionCell {
                        self.configure(cell, row: self.rows[index])
                    }
                }
            }
            if value.selectedID != old?.selectedID, let selected = value.selectedID,
               let index = rows.firstIndex(where: { $0.id == selected }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
        }

        func saveAnchor() {
            guard input != nil, let anchor = anchor() else { return }
            state.scrollAnchors[storageKey] = anchor
        }
        private func anchor() -> (id: String, offset: CGFloat)? {
            guard let table, !rows.isEmpty else { return nil }
            let index = table.row(at: NSPoint(x: 1, y: table.visibleRect.minY + 1))
            guard rows.indices.contains(index) else { return nil }
            return (rows[index].id, table.visibleRect.minY - table.rect(ofRow: index).minY)
        }
        private func restore(_ anchor: (id: String, offset: CGFloat)?) {
            guard let anchor, let table, let scroll = table.enclosingScrollView,
                  let index = rows.firstIndex(where: { $0.id == anchor.id }) else { return }
            let y = table.rect(ofRow: index).minY + anchor.offset
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(y, max(0, table.bounds.height - scroll.contentSize.height)))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        private func apply(_ next: [GitCollectionRow], reset: Bool, preferredSelection: String?) {
            guard let table, let input else { return }
            let previous = rows
            let oldIDs = previous.map(\.id)
            let newIDs = next.map(\.id)
            let selection = input.interaction == .changes ? state.selections[input.stateKey, default: []] : []
            table.clearHover()
            var saved = reset ? state.scrollAnchors[storageKey] : anchor()
            if !reset, let top = saved, !newIDs.contains(top.id), let first = oldIDs.firstIndex(of: top.id) {
                let survivors = Set(newIDs)
                if let index = (first..<oldIDs.count).first(where: { survivors.contains(oldIDs[$0]) }) {
                    saved = (oldIDs[index], table.visibleRect.minY - table.rect(ofRow: index).minY)
                }
            }
            updating = true
            defer { updating = false; table.updateHoverFromPointer() }
            rows = next
            if reset || previous.isEmpty {
                table.reloadData()
            } else {
                var removed = IndexSet()
                var inserted = IndexSet()
                let oldSet = Set(oldIDs)
                let newSet = Set(newIDs)
                // Sorted collections retain the relative order of surviving
                // rows. Avoid a quadratic diff when an external `git add .`
                // moves thousands of entries between index sides at once.
                if oldIDs.filter(newSet.contains) == newIDs.filter(oldSet.contains) {
                    for (index, id) in oldIDs.enumerated() where !newSet.contains(id) { removed.insert(index) }
                    for (index, id) in newIDs.enumerated() where !oldSet.contains(id) { inserted.insert(index) }
                } else {
                    for change in newIDs.difference(from: oldIDs) {
                        switch change {
                        case .remove(let index, _, _): removed.insert(index)
                        case .insert(let index, _, _): inserted.insert(index)
                        }
                    }
                }
                let oldRows = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
                var updated = IndexSet()
                var resized = IndexSet()
                for (index, row) in next.enumerated() where !inserted.contains(index) {
                    if oldRows[row.id] != row { updated.insert(index) }
                    if oldRows[row.id]?.height != row.height { resized.insert(index) }
                }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    context.allowsImplicitAnimation = false
                    if !removed.isEmpty || !inserted.isEmpty {
                        table.beginUpdates()
                        table.removeRows(at: removed, withAnimation: [])
                        table.insertRows(at: inserted, withAnimation: [])
                        table.endUpdates()
                    }
                    if !resized.isEmpty { table.noteHeightOfRows(withIndexesChanged: resized) }
                    if !updated.isEmpty { table.reloadData(forRowIndexes: updated, columnIndexes: IndexSet(integer: 0)) }
                }
            }
            if input.interaction == .changes {
                let remapped = remapSelection(selection, previous: previous, next: next)
                if let anchor = selectionAnchorID {
                    selectionAnchorID = remapSelection([anchor], previous: previous, next: next).first
                }
                table.selectRowIndexes(IndexSet(next.indices.filter { remapped.contains(next[$0].id) && next[$0].item.isSelectable }), byExtendingSelection: false)
                state.selections[input.stateKey] = Set(table.selectedRowIndexes.map { next[$0].id })
            } else if let selected = preferredSelection, let index = rows.firstIndex(where: { $0.id == selected && $0.item.isSelectable }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            } else if input.interaction == .picker, let index = rows.firstIndex(where: { $0.item.isSelectable && !$0.item.isFolder && $0.item.enabled }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            } else { table.deselectAll(nil) }
            if rows.indices.contains(table.selectedRow) {
                state.selected[input.stateKey] = rows[table.selectedRow].id
            }
            restore(saved)
        }

        func toggleFolder(_ id: String) {
            guard let input else { return }
            var collapsed = input.query.isEmpty ? state.collapsed[input.stateKey, default: []] : filterCollapsed
            let row = rows.first { $0.id == id }
            let collapsing = row?.expanded ?? !collapsed.contains(id)
            var identities = row?.representedIDs.isEmpty == false ? row!.representedIDs : [id]
            if input.interaction == .changes {
                identities += identities.filter { $0.contains("/folder/") }.map {
                    $0.contains("changes/staged/")
                        ? $0.replacingOccurrences(of: "changes/staged/", with: "changes/unstaged/")
                        : $0.replacingOccurrences(of: "changes/unstaged/", with: "changes/staged/")
                }
            }
            for identity in identities {
                if collapsing { collapsed.insert(identity) } else { collapsed.remove(identity) }
            }
            if input.query.isEmpty { state.collapsed[input.stateKey] = collapsed } else { filterCollapsed = collapsed }
            apply(GitCollectionBuilder.rows(nodes, collapsed: collapsed), reset: false, preferredSelection: id)
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row].height }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row].item.isSelectable }
        func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
            guard !updating, input?.interaction == .changes, table?.clickModifiers.contains(.shift) == true else { return proposed }
            let target = table?.selectionClickRow ?? proposed.last ?? 0
            let anchor = selectionAnchorID.flatMap { id in rows.firstIndex { $0.id == id } } ?? max(0, table?.selectedRow ?? target)
            return IndexSet((min(anchor, target)...max(anchor, target)).filter { index in
                guard rows.indices.contains(index) else { return false }
                if case .file = rows[index].item.kind { return true }; return false
            })
        }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = GitCollectionRowView()
            view.colors = input?.colors ?? .init()
            view.showsHighlight = rows[row].item.isSelectable
            view.isPointerHovered = table?.hoveredRowID == rows[row].id
            view.isMultipleSelection = (table?.selectedRowIndexes.count ?? 0) > 1
            return view
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cell = tableView.makeView(withIdentifier: .init("git-collection-row"), owner: nil) as? GitCollectionCell ?? GitCollectionCell()
            cell.identifier = .init("git-collection-row")
            configure(cell, row: rows[row])
            return cell
        }
        private func configure(_ cell: GitCollectionCell, row: GitCollectionRow) {
            var displayed = row
            if let table, table.selectedRowIndexes.count > 1, selectedRows.contains(row.id),
               let batch = selectedBatch, !batch.paths.isDisjoint(with: input?.pending ?? []) { displayed.item.enabled = false }
            cell.configure(displayed, colors: input?.colors ?? .init(), toggle: { [weak self] in self?.toggleFolder(row.id) },
                           stage: { [weak self] in self?.toggleStage(rowID: row.id) })
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table, let input else { return }
            if input.interaction == .changes { state.selections[input.stateKey] = selectedRows }
            if !table.clickModifiers.contains(.shift), let row = table.selectionClickRow, rows.indices.contains(row) { selectionAnchorID = rows[row].id }
            if rows.indices.contains(table.selectedRow) { state.selected[input.stateKey] = rows[table.selectedRow].id } else { state.selected.removeValue(forKey: input.stateKey) }
            table.refreshRowBackgrounds()
            table.enumerateAvailableRowViews { _, index in
                if self.rows.indices.contains(index), let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? GitCollectionCell {
                    self.configure(cell, row: self.rows[index])
                }
            }
        }
        func moveSelection(_ direction: Int) {
            guard let table else { return }
            let start = table.selectedRow < 0 ? (direction > 0 ? -1 : rows.count) : table.selectedRow
            var index = start + direction
            while rows.indices.contains(index) {
                let item = rows[index].item
                if item.isSelectable && !item.isFolder && item.enabled {
                    table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                    table.scrollRowToVisible(index)
                    return
                }
                index += direction
            }
        }
        func select(row: Int, modifiers: NSEvent.ModifierFlags, clickCount: Int = 1) {
            guard let table, rows.indices.contains(row), rows[row].item.isSelectable else { return }
            var selected = table.selectedRowIndexes
            if modifiers.contains(.shift) {
                let anchor = selectionAnchorID.flatMap { id in rows.firstIndex { $0.id == id } } ?? row
                let range = IndexSet((min(anchor, row)...max(anchor, row)).filter {
                    if case .file = rows[$0].item.kind { return true }; return false
                })
                selected = modifiers.contains(.command) ? selected.union(range) : range
            } else if modifiers.contains(.command) {
                if !selected.insert(row).inserted { selected.remove(row) }
                selectionAnchorID = rows[row].id
            } else {
                selected = IndexSet(integer: row)
                selectionAnchorID = rows[row].id
            }
            table.selectRowIndexes(selected, byExtendingSelection: false)
            if modifiers.isEmpty {
                if !rows[row].item.isFolder || clickCount > 1 { activate(row: row) }
            }
        }
        @objc func clicked() {
            guard let table, rows.indices.contains(table.clickedRow), let input else { return }
            if !table.clickModifiers.contains(.shift) { selectionAnchorID = rows[table.clickedRow].id }
            if input.interaction == .changes, !table.clickModifiers.isEmpty || table.selectedRowIndexes.count > 1 { return }
            if input.interaction == .picker || input.interaction == .changes || input.interaction == .references {
                if !rows[table.clickedRow].item.isFolder { activate(row: table.clickedRow) }
            }
        }
        @objc func doubleClicked() {
            guard let table else { return }
            if input?.interaction == .changes, !table.clickModifiers.isEmpty || table.selectedRowIndexes.count > 1 { return }
            if input?.interaction != .picker { activate(row: table.clickedRow >= 0 ? table.clickedRow : table.selectedRow) }
        }
        func activateSelected() { if let table { activate(row: table.selectedRow) } }

        private var selectedRows: Set<String> {
            guard let table else { return [] }
            return Set(table.selectedRowIndexes.filter { rows.indices.contains($0) }.map { rows[$0].id })
        }
        private var selectedBatch: GitStageBatch? {
            let selected = selectedRows
            let entries = rows.filter { selected.contains($0.id) }.flatMap { $0.item.stageBatch?.entries ?? [] }
            return entries.isEmpty ? nil : .init(entries: entries)
        }
        func toggleSelectedStage() {
            if let batch = selectedBatch { submit(batch) }
        }
        func toggleStage(rowID: String) {
            guard let row = rows.first(where: { $0.id == rowID }) else { return }
            if selectedRows.count > 1, selectedRows.contains(rowID), let batch = selectedBatch { submit(batch) } else if let batch = row.item.stageBatch { submit(batch) }
        }
        private func submit(_ batch: GitStageBatch) {
            guard let input, input.canWrite, !batch.isEmpty, batch.paths.isDisjoint(with: input.pending) else { return }
            if batch.entries.count == 1, let file = batch.files.first { input.perform(.setFileStaged(file, batch.shouldStage)) } else { input.perform(.setFilesStaged(batch.files, batch.shouldStage)) }
        }
        func clearSelection() {
            selectionAnchorID = nil
            table?.deselectAll(nil)
            if let input { state.selections.removeValue(forKey: input.stateKey); state.selected.removeValue(forKey: input.stateKey) }
        }
        private func remapSelection(_ selected: Set<String>, previous: [GitCollectionRow], next: [GitCollectionRow]) -> Set<String> {
            let existing = Set(next.map(\.id))
            var visibleIDs: [String: String] = [:]
            for row in next {
                visibleIDs[row.id] = row.id
                for id in row.representedIDs { visibleIDs[id] = row.id }
            }
            var result = Set(selected.compactMap { visibleIDs[$0] })
            for row in previous where selected.contains(row.id) && !existing.contains(row.id) {
                if let replacement = visibleIDs[row.id] {
                    result.insert(replacement)
                    continue
                }
                switch row.item.kind {
                case .file(let file, let section):
                    let other = (section == .staged ? GitChangeSection.unstaged : .staged).rowID(path: file.path)
                    if let visible = visibleIDs[other] { result.insert(visible) }
                case .folder:
                    let other = row.id.contains("changes/staged/") ? row.id.replacingOccurrences(of: "changes/staged/", with: "changes/unstaged/")
                        : row.id.replacingOccurrences(of: "changes/unstaged/", with: "changes/staged/")
                    if let visible = visibleIDs[other] { result.insert(visible) }
                default: break
                }
            }
            return result
        }
        func activate(row index: Int) {
            guard rows.indices.contains(index), let input else { return }
            let item = rows[index].item
            if item.isFolder { toggleFolder(item.id); return }
            guard item.enabled else { return }
            switch item.kind {
            case .ref(let ref):
                if input.interaction == .references { input.referenceAction(ref) } else { input.perform(.browseRef(ref.fullRef)) }
            case .folder: toggleFolder(item.id)
            case .file(let file, let section): input.perform(.openDiff(file, section.target))
            case .branch(let branch, _):
                if input.interaction == .branches, worktreesAvailable, let occupied = worktrees.first(where: { $0.branchRef == branch.id }), occupied.canOpen {
                    input.perform(.openWorktree(occupied.path))
                } else { input.perform(.browseBranch(branch.id)) }
            case .worktree(let worktree):
                if input.interaction == .picker { input.perform(.browseWorktree(worktree.path)) } else if worktree.canOpen { input.perform(.openWorktree(worktree.path)) }
            case .scope(let scope): input.perform(.selectHistoryScope(scope))
            default: break
            }
        }
        private var worktrees: [GitWorktreeInfo] {
            guard case .refs(_, let trees, _, _, _) = input?.source else { return [] }
            return trees
        }
        private var worktreesAvailable: Bool {
            guard case .refs(_, _, _, _, let error) = input?.source else { return false }
            return error == nil
        }
        private func copySelected() {
            if let value = selectedCopyValue() { InspectorCopyMenu.copy(value, to: table?.pasteboard ?? .general) }
        }
        private func selectedCopyValue() -> String? {
            guard let table, rows.indices.contains(table.selectedRow) else { return nil }
            return table.selectedRowIndexes.filter { rows.indices.contains($0) }.map { index in
                let item = rows[index].item
                switch item.kind {
                case .ref(let ref): return ref.name
                case .file(let file, _): return file.path
                case .branch(let branch, _): return branch.name
                case .worktree(let tree): return tree.path
                default: return item.title
                }
            }.joined(separator: "\n")
        }

        func contextBatch(row: Int) -> GitStageBatch? {
            guard rows.indices.contains(row) else { return nil }
            return selectedRows.contains(rows[row].id) ? selectedBatch : rows[row].item.stageBatch
        }

        private enum MenuCommand { case action(InspectorGitAction), copy(String) }
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            menu.autoenablesItems = false
            guard let table, let input else { return }
            let index = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
            guard rows.indices.contains(index) else { return }
            let item = rows[index].item
            func add(_ title: String, _ command: MenuCommand, enabled: Bool = true) {
                let value = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
                value.target = self; value.representedObject = command; value.isEnabled = enabled
                menu.addItem(value)
            }
            switch item.kind {
            case .ref(let ref): add(GitL10n.text("Copy full ref name"), .copy(ref.name))
            case .branch(let branch, _):
                let occupied = worktrees.first { $0.branchRef == branch.id }
                if let occupied { add(GitL10n.text("Open Worktree in New Tab"), .action(.openWorktree(occupied.path)), enabled: worktreesAvailable && occupied.canOpen) }
                add(GitL10n.text("Show History"), .action(.browseBranch(branch.id)), enabled: item.enabled)
                add(GitL10n.text("New Worktree from Here…"), .action(.createWorktree(branch.id)), enabled: input.canWrite && worktreesAvailable && item.enabled)
                menu.addItem(.separator())
                add(branch.isRemote ? GitL10n.text("Checkout Tracking Branch…") : GitL10n.text("Switch Branch"), .action(.branchOperation(.checkout, branch.id)),
                    enabled: input.canWrite && item.enabled && !branch.isCurrent && occupied == nil)
                add(GitL10n.text("New Branch from Here…"), .action(.branchOperation(.create, branch.id)), enabled: input.canWrite && item.enabled)
                if !branch.isRemote {
                    add(GitL10n.text("Push…"), .action(.branchOperation(.push, branch.id)), enabled: input.canWrite && item.enabled)
                    add(GitL10n.text("Set Upstream…"), .action(.branchOperation(.setUpstream, branch.id)), enabled: input.canWrite && item.enabled)
                }
                menu.addItem(.separator())
                add(GitL10n.text("Copy Branch Name"), .copy(branch.name))
            case .worktree(let tree):
                add(GitL10n.text("Open in New Tab"), .action(.openWorktree(tree.path)), enabled: item.enabled && tree.canOpen)
                add(GitL10n.text("Copy Worktree Path"), .copy(tree.path))
                add(GitL10n.text("Remove Worktree…"), .action(.removeWorktree(tree.path)), enabled: input.canWrite && item.enabled && tree.canRemove)
            case .file(let file, let section):
                if let batch = contextBatch(row: index) {
                    let enabledIDs = Set(rows.filter { $0.item.enabled }.map(\.id))
                    let enabled = input.canWrite && batch.paths.isDisjoint(with: input.pending)
                        && batch.entries.allSatisfy { entry in
                            enabledIDs.contains(entry.section.rowID(path: entry.file.path))
                        }
                    let multiple = batch.entries.count > 1
                    let title = multiple ? (batch.shouldStage ? "Stage Selected Files" : "Unstage Selected Files")
                        : (batch.shouldStage ? "Stage File" : "Unstage File")
                    let stageAction: InspectorGitAction = multiple ? .setFilesStaged(batch.files, batch.shouldStage)
                        : .setFileStaged(file, batch.shouldStage)
                    let discardAction: InspectorGitAction = multiple ? .discardSelectedChanges(batch)
                        : .discardChanges(file, staged: section == .staged)
                    add(GitL10n.text(title), .action(stageAction), enabled: enabled)
                    add(GitL10n.text(multiple ? "Discard Selected Changes…" : "Discard Changes…"),
                        .action(discardAction),
                        enabled: enabled && batch.entries.allSatisfy { $0.file.kind != .unmerged })
                }
                menu.addItem(.separator())
                add(GitL10n.text("Open Diff"), .action(.openDiff(file, section.target)))
                add(GitL10n.text("Open in Editor"), .action(.openGitFile(file, directory: false)), enabled: file.kind != .deleted)
                add(GitL10n.text("Open Folder in New Tab"), .action(.openGitFile(file, directory: true)))
                add(GitL10n.text("Copy Path"), .copy(file.path))
            default: break
            }
        }
        @objc private func menuAction(_ sender: NSMenuItem) {
            guard let command = sender.representedObject as? MenuCommand else { return }
            switch command {
            case .action(let action): input?.perform(action)
            case .copy(let value): InspectorCopyMenu.copy(value, to: table?.pasteboard ?? .general)
            }
        }
    }
}
