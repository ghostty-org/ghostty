import AppKit
import Combine
import SwiftUI

private struct TerminalWorkspaceRowSnapshot: Equatable {
    let id: UUID
    let name: String
    let symbol: String
    let color: String
    let tabCount: Int
    let isCurrent: Bool
    let shortcut: String?
    let canDelete: Bool
    let actionsEnabled: Bool
}

private struct TerminalWorkspaceRowActions {
    let open: () -> Void
    let edit: () -> Void
    let delete: () -> Void
}

@MainActor
final class TerminalWorkspacePickerController: NSViewController, NSSearchFieldDelegate, NSTextFieldDelegate,
                                               NSTableViewDataSource, NSTableViewDelegate {
    private let model: TerminalWorkspacePickerModel
    private var cancellables = Set<AnyCancellable>()
    private let root = NSView()
    private let stack = NSStackView()
    private let header = NSStackView()
    private let backButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: "")
    private let createButton = NSButton()
    private let content = NSView()
    private let queryField = NSSearchField()
    private let moveTitle = NSTextField(wrappingLabelWithString: "")
    private let table = TerminalWorkspaceTableView()
    private let scroll = NSScrollView()
    private let footer = NSTextField(labelWithString: "")
    private let moveButton = NSButton()
    private let previewIcon = NSImageView()
    private let nameField = NSTextField()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let noticeLabel = NSTextField(wrappingLabelWithString: "")
    private let deleteTitleLabel = NSTextField(labelWithString: "")
    private let deleteDescriptionLabel = NSTextField(wrappingLabelWithString: "")
    private let cancelButton = NSButton()
    private let confirmButton = NSButton()
    private var symbolButtons: [NSButton] = []
    private var colorButtons: [NSButton] = []
    private var lastPage: TerminalWorkspacePickerModel.Page?
    private var lastRows: [TerminalWorkspaceRowSnapshot] = []
    private var isSyncingSelection = false
    private var scrollHeightConstraint: NSLayoutConstraint?
    var onPreferredSizeChange: ((NSSize) -> Void)?

    init(model: TerminalWorkspacePickerModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                DispatchQueue.main.async { self?.render() }
            }
            .store(in: &cancellables)
        model.store.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.render() } }
            .store(in: &cancellables)
        model.store.$saveError
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.render() } }
            .store(in: &cancellables)
        model.coordinator.$revision
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.render() } }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        root.wantsLayer = true
        root.setAccessibilityIdentifier("workspace.picker")

        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        backButton.bezelStyle = .toolbar
        backButton.target = self
        backButton.action = #selector(goBack)
        backButton.setAccessibilityLabel(WorkspaceL10n.text("Back", "返回"))
        backButton.setAccessibilityIdentifier("workspace.back")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        createButton.title = WorkspaceL10n.text("New", "新建")
        createButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        createButton.imagePosition = .imageLeading
        createButton.bezelStyle = .rounded
        createButton.controlSize = .small
        createButton.target = self
        createButton.action = #selector(beginCreate)
        createButton.setAccessibilityLabel(WorkspaceL10n.text("Create a workspace", "创建工作区"))
        createButton.setAccessibilityIdentifier("workspace.create")
        header.addArrangedSubview(backButton)
        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(createButton)

        queryField.placeholderString = WorkspaceL10n.text("Search workspaces", "搜索工作区")
        queryField.sendsSearchStringImmediately = true
        queryField.delegate = self
        queryField.target = self
        queryField.action = #selector(searchChanged(_:))
        queryField.setAccessibilityIdentifier("workspace.search")
        moveTitle.maximumNumberOfLines = 2
        moveTitle.textColor = .secondaryLabelColor
        moveTitle.font = .systemFont(ofSize: 11)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("workspace"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 54
        table.intercellSpacing = .zero
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(activateSelected(_:))
        table.onEscape = { [weak self] in self?.model.cancel() }
        table.onMove = { [weak self] delta in self?.model.step(delta) }
        table.onActivate = { [weak self] in self?.model.activateSelected() }
        table.setAccessibilityIdentifier("workspace.list")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        footer.font = .systemFont(ofSize: 10)
        footer.textColor = .tertiaryLabelColor
        footer.maximumNumberOfLines = 2
        footer.lineBreakMode = .byWordWrapping
        moveButton.title = WorkspaceL10n.text("Move current tab…", "移动当前标签…")
        moveButton.image = NSImage(systemSymbolName: "arrow.right.square", accessibilityDescription: nil)
        moveButton.imagePosition = .imageLeading
        moveButton.bezelStyle = .rounded
        moveButton.controlSize = .small
        moveButton.alignment = .left
        moveButton.target = self
        moveButton.action = #selector(beginMove)
        moveButton.setAccessibilityIdentifier("workspace.move")
        previewIcon.widthAnchor.constraint(equalToConstant: 38).isActive = true
        previewIcon.heightAnchor.constraint(equalToConstant: 38).isActive = true
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemOrange
        errorLabel.maximumNumberOfLines = 3
        noticeLabel.font = .systemFont(ofSize: 11)
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.maximumNumberOfLines = 2
        cancelButton.title = WorkspaceL10n.text("Cancel", "取消")
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.keyEquivalentModifierMask = []
        cancelButton.target = self
        cancelButton.action = #selector(cancelPage)
        confirmButton.bezelStyle = .rounded
        confirmButton.target = self

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        [header, content, errorLabel, noticeLabel].forEach(stack.addArrangedSubview)
        stack.setCustomSpacing(8, after: header)
        stack.setCustomSpacing(8, after: content)
        stack.setCustomSpacing(5, after: errorLabel)
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            content.widthAnchor.constraint(equalTo: stack.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            noticeLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = root
        render()
    }

    func update(model next: TerminalWorkspacePickerModel) {
        guard model === next else { return }
        render()
    }

    func fittingSize(proposedWidth _: CGFloat?) -> CGSize {
        let height: CGFloat
        switch model.page {
        case .switcher:
            height = 170 + listHeight
        case .move:
            height = 180 + listHeight
        case .create, .edit:
            height = isViewLoaded ? max(380, root.fittingSize.height) : 400
        case .delete:
            height = 230
        }
        let statusHeight: CGFloat = model.error != nil || model.store.saveError != nil ? 36 :
            model.notice != nil ? 24 : 0
        return CGSize(width: 360, height: min(height + statusHeight, 560))
    }

    private var listHeight: CGFloat { min(330, 54 * CGFloat(max(1, model.filtered.count))) }

    private func render() {
        guard isViewLoaded else { return }
        if lastPage != model.page {
            lastPage = model.page
            rebuildPage()
        }
        let title: String
        switch model.page {
        case .switcher: title = WorkspaceL10n.text("Workspaces", "工作区")
        case .create: title = WorkspaceL10n.text("New Workspace", "新建工作区")
        case .edit: title = WorkspaceL10n.text("Edit Workspace", "编辑工作区")
        case .move: title = WorkspaceL10n.text("Move Tab", "移动标签")
        case .delete: title = WorkspaceL10n.text("Delete Workspace", "删除工作区")
        }
        titleLabel.stringValue = title
        backButton.isHidden = model.page == .switcher
        createButton.isHidden = model.page != .switcher
        createButton.isEnabled = model.canCreate && !model.isPerforming
        errorLabel.stringValue = model.error ?? model.store.saveError ?? ""
        errorLabel.isHidden = errorLabel.stringValue.isEmpty
        noticeLabel.stringValue = model.notice ?? ""
        noticeLabel.isHidden = noticeLabel.stringValue.isEmpty || !errorLabel.isHidden
        if model.page == .switcher || model.page == .move {
            if queryField.currentEditor() == nil, queryField.stringValue != model.query {
                queryField.stringValue = model.query
            }
            moveTitle.stringValue = WorkspaceL10n.text(
                "Move “\(model.movingTabTitle)” to…",
                "将“\(model.movingTabTitle)”移动到…"
            )
            moveTitle.isHidden = model.page != .move
            footer.stringValue = model.filtered.isEmpty && !model.query.isEmpty
                ? WorkspaceL10n.text("No workspaces match.", "没有匹配的工作区。")
                : WorkspaceL10n.text("↑ ↓ Choose  ·  Return Confirm  ·  Esc Back",
                                      "↑ ↓ 选择  ·  回车确认  ·  Esc 返回")
            footer.isHidden = false
            footer.textColor = .tertiaryLabelColor
            let rows = model.filtered.map { workspace in
                TerminalWorkspaceRowSnapshot(
                    id: workspace.id,
                    name: workspace.name,
                    symbol: workspace.symbol,
                    color: workspace.color,
                    tabCount: model.tabCount(workspace.id),
                    isCurrent: workspace.id == model.currentID,
                    shortcut: shortcut(for: workspace.id),
                    canDelete: model.canDelete(workspace.id),
                    actionsEnabled: !model.isPerforming
                )
            }
            if lastRows != rows {
                lastRows = rows
                isSyncingSelection = true
                table.reloadData()
                isSyncingSelection = false
            }
            scrollHeightConstraint?.constant = listHeight
            moveButton.isEnabled = !model.isPerforming && model.store.workspaces.count > 1
            syncSelection()
        } else if model.page == .create || isEditingPage {
            renderEditorControls()
        } else if case .delete(let id) = model.page {
            renderDeletionControls(id: id)
        }
        cancelButton.isEnabled = !model.isPerforming
        queryField.isEnabled = !model.isPerforming
        nameField.isEnabled = !model.isPerforming
        table.isEnabled = !model.isPerforming
        symbolButtons.forEach { $0.isEnabled = !model.isPerforming }
        colorButtons.forEach { $0.isEnabled = !model.isPerforming }
        view.window?.invalidateCursorRects(for: view)
        let size = fittingSize(proposedWidth: nil)
        if preferredContentSize != size {
            preferredContentSize = size
            onPreferredSizeChange?(size)
        }
    }

    private func rebuildPage() {
        scrollHeightConstraint?.isActive = false
        scrollHeightConstraint = nil
        content.subviews.forEach { $0.removeFromSuperview() }
        let pageStack = NSStackView()
        pageStack.orientation = .vertical
        pageStack.alignment = .leading
        pageStack.spacing = 10
        pageStack.translatesAutoresizingMaskIntoConstraints = false
        switch model.page {
        case .switcher, .move:
            if model.page == .move { pageStack.addArrangedSubview(moveTitle) }
            queryField.translatesAutoresizingMaskIntoConstraints = false
            pageStack.addArrangedSubview(queryField)
            pageStack.addArrangedSubview(scroll)
            if model.page == .switcher {
                pageStack.addArrangedSubview(moveButton)
                moveButton.widthAnchor.constraint(equalTo: pageStack.widthAnchor).isActive = true
            }
            pageStack.addArrangedSubview(footer)
            queryField.widthAnchor.constraint(equalTo: pageStack.widthAnchor).isActive = true
            scroll.widthAnchor.constraint(equalTo: pageStack.widthAnchor).isActive = true
            footer.widthAnchor.constraint(equalTo: pageStack.widthAnchor).isActive = true
            let height = scroll.heightAnchor.constraint(equalToConstant: listHeight)
            height.isActive = true
            scrollHeightConstraint = height
        case .create, .edit:
            buildEditor(into: pageStack)
        case .delete(let id):
            buildDeletion(id: id, into: pageStack)
        }
        content.addSubview(pageStack)
        NSLayoutConstraint.activate([
            pageStack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pageStack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pageStack.topAnchor.constraint(equalTo: content.topAnchor),
            pageStack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        content.setAccessibilityIdentifier("workspace.page.\(pageIdentifier)")
        lastRows = []
        render()
        DispatchQueue.main.async { [weak self] in self?.focusPage() }
    }

    private var pageIdentifier: String {
        switch model.page {
        case .switcher: "switcher"
        case .move: "move"
        case .create: "create"
        case .edit: "edit"
        case .delete: "delete"
        }
    }

    private func buildEditor(into pageStack: NSStackView) {
        let identity = NSStackView()
        identity.orientation = .horizontal
        identity.alignment = .centerY
        identity.spacing = 8
        previewIcon.imageScaling = .scaleProportionallyDown
        previewIcon.setAccessibilityIdentifier("workspace.preview")
        nameField.placeholderString = WorkspaceL10n.text("Workspace name", "工作区名称")
        nameField.delegate = self
        nameField.target = self
        nameField.action = #selector(nameSubmitted)
        nameField.setAccessibilityIdentifier("workspace.name")
        identity.addArrangedSubview(previewIcon)
        identity.addArrangedSubview(nameField)
        pageStack.addArrangedSubview(identity)
        NSLayoutConstraint.activate([
            identity.widthAnchor.constraint(equalTo: pageStack.widthAnchor),
            nameField.widthAnchor.constraint(equalTo: pageStack.widthAnchor, constant: -46),
        ])
        addSection(WorkspaceL10n.text("Icon", "图标"), into: pageStack)
        symbolButtons = makeSymbolButtons()
        pageStack.addArrangedSubview(grid(symbolButtons, columns: 8, buttonSize: 30))
        addSection(WorkspaceL10n.text("Color", "颜色"), into: pageStack)
        colorButtons = makeColorButtons()
        pageStack.addArrangedSubview(grid(colorButtons, columns: 7, buttonSize: 30))
        pageStack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: pageStack.widthAnchor).isActive = true

        let buttons = NSStackView(views: [cancelButton, NSView(), confirmButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        pageStack.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalTo: pageStack.widthAnchor).isActive = true
    }

    private func buildDeletion(id: UUID, into pageStack: NSStackView) {
        deleteTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        deleteDescriptionLabel.font = .systemFont(ofSize: 12)
        deleteDescriptionLabel.textColor = .secondaryLabelColor
        deleteDescriptionLabel.maximumNumberOfLines = 0
        let buttons = NSStackView(views: [cancelButton, NSView(), confirmButton])
        buttons.orientation = .horizontal
        pageStack.addArrangedSubview(deleteTitleLabel)
        pageStack.addArrangedSubview(deleteDescriptionLabel)
        pageStack.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalTo: pageStack.widthAnchor).isActive = true
        confirmButton.title = WorkspaceL10n.text("Delete Workspace", "删除工作区")
        confirmButton.contentTintColor = .systemRed
        confirmButton.action = #selector(confirmDelete)
        confirmButton.setAccessibilityIdentifier("workspace.confirm-delete")
        renderDeletionControls(id: id)
    }

    private func addSection(_ title: String, into stack: NSStackView) {
        let field = NSTextField(labelWithString: title)
        field.font = .systemFont(ofSize: 11, weight: .semibold)
        field.textColor = .secondaryLabelColor
        stack.addArrangedSubview(field)
    }

    private func grid(_ buttons: [NSButton], columns: Int, buttonSize: CGFloat) -> NSGridView {
        let rows = stride(from: 0, to: buttons.count, by: columns).map { start in
            Array(buttons[start..<min(start + columns, buttons.count)]).map { button in
                button.translatesAutoresizingMaskIntoConstraints = false
                button.widthAnchor.constraint(equalToConstant: buttonSize).isActive = true
                button.heightAnchor.constraint(equalToConstant: buttonSize).isActive = true
                return button as NSView
            }
        }
        let result = NSGridView(views: rows)
        result.rowSpacing = 5
        result.columnSpacing = 5
        result.xPlacement = .center
        result.yPlacement = .center
        result.heightAnchor.constraint(
            equalToConstant: CGFloat(rows.count) * buttonSize + CGFloat(max(0, rows.count - 1)) * 5
        ).isActive = true
        for index in 0..<result.numberOfColumns {
            result.column(at: index).width = (340 - CGFloat(columns - 1) * 5) / CGFloat(columns)
        }
        return result
    }

    private func makeSymbolButtons() -> [NSButton] {
        TerminalWorkspace.symbols.map { symbol in
            let button = NSButton()
            button.title = ""
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
            button.imagePosition = .imageOnly
            button.bezelStyle = .regularSquare
            button.setButtonType(.toggle)
            button.target = self
            button.action = #selector(selectSymbol(_:))
            button.identifier = NSUserInterfaceItemIdentifier("symbol.\(symbol)")
            button.setAccessibilityLabel(symbol)
            return button
        }
    }

    private func makeColorButtons() -> [NSButton] {
        TerminalWorkspace.colors.map { color in
            let button = NSButton()
            button.title = ""
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.bezelStyle = .regularSquare
            button.setButtonType(.toggle)
            button.target = self
            button.action = #selector(selectColor(_:))
            button.identifier = NSUserInterfaceItemIdentifier("color.\(color)")
            button.setAccessibilityLabel(color)
            button.wantsLayer = true
            button.layer?.cornerRadius = 15
            button.layer?.backgroundColor = nsColor(for: color).cgColor
            return button
        }
    }

    private func nsColor(for name: String) -> NSColor {
        switch name {
        case "green": .systemGreen
        case "mint": .systemMint
        case "teal": .systemTeal
        case "blue": NSColor(calibratedRed: 0.57, green: 0.68, blue: 0.79, alpha: 1)
        case "indigo": .systemIndigo
        case "purple": .systemPurple
        case "rose": NSColor(calibratedRed: 0.79, green: 0.59, blue: 0.63, alpha: 1)
        case "red": .systemRed
        case "orange": .systemOrange
        case "amber": NSColor(calibratedRed: 0.80, green: 0.67, blue: 0.46, alpha: 1)
        case "gray": .systemGray
        case "accent": .controlAccentColor
        default: NSColor(calibratedRed: 0.60, green: 0.71, blue: 0.64, alpha: 1)
        }
    }

    private func renderEditorControls() {
        previewIcon.image = NSImage(systemSymbolName: model.symbol, accessibilityDescription: model.symbol)
        previewIcon.contentTintColor = nsColor(for: model.color)
        if nameField.currentEditor() == nil, nameField.stringValue != model.name {
            nameField.stringValue = model.name
        }
        for button in symbolButtons {
            let selected = button.identifier?.rawValue == "symbol.\(model.symbol)"
            button.state = selected ? .on : .off
            button.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
        }
        for button in colorButtons {
            button.state = button.identifier?.rawValue == "color.\(model.color)" ? .on : .off
            button.image = button.state == .on
                ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: model.color)
                : nil
            button.contentTintColor = .white
        }
        confirmButton.title = model.page == .create
            ? WorkspaceL10n.text("Create & Open", "创建并打开")
            : WorkspaceL10n.text("Save", "保存")
        confirmButton.contentTintColor = nil
        confirmButton.action = #selector(save)
        confirmButton.keyEquivalent = "\r"
        confirmButton.keyEquivalentModifierMask = []
        confirmButton.setAccessibilityIdentifier("workspace.save")
        confirmButton.isEnabled = !model.isPerforming && model.validName
        footer.stringValue = model.name.count > 40
            ? WorkspaceL10n.text("Use 40 characters or fewer.", "名称最多 40 个字符。")
            : model.duplicateName
                ? WorkspaceL10n.text("Another workspace uses this name. A distinct name is easier to recognize.",
                                     "已有同名工作区，使用不同名称更容易区分。")
                : ""
        footer.textColor = .secondaryLabelColor
        footer.isHidden = footer.stringValue.isEmpty
    }

    private func renderDeletionControls(id: UUID) {
        let workspace = model.store.workspace(id)
        let destination = model.deletionDestination ?? model.store.workspace(model.store.defaultID)
        deleteTitleLabel.stringValue = WorkspaceL10n.text(
            "Delete “\(workspace.name)” ?", "删除“\(workspace.name)”？"
        )
        deleteDescriptionLabel.stringValue = WorkspaceL10n.text(
            "Its \(model.tabCount(id, allWindows: true)) tabs will move to “\(destination.name)” in their own windows. Running sessions will stay open.",
            "其中的 \(model.tabCount(id, allWindows: true)) 个标签将移至各自窗口的“\(destination.name)”。运行中的会话会保留。"
        )
        confirmButton.title = WorkspaceL10n.text("Delete Workspace", "删除工作区")
        confirmButton.contentTintColor = .systemRed
        confirmButton.action = #selector(confirmDelete)
        confirmButton.keyEquivalent = ""
        confirmButton.setAccessibilityIdentifier("workspace.confirm-delete")
        confirmButton.isEnabled = !model.isPerforming && model.canDelete(id)
    }

    private var isEditingPage: Bool {
        if case .edit = model.page { return true }
        return false
    }

    @objc private func goBack() { model.back() }
    @objc private func beginCreate() { model.beginCreate() }
    @objc private func beginMove() { model.beginMove() }
    @objc private func cancelPage() { model.cancel() }
    @objc private func save() { model.save() }
    @objc private func confirmDelete() { model.confirmDelete() }
    @objc private func nameSubmitted() { model.save() }
    @objc private func searchChanged(_ sender: NSSearchField) {
        model.query = sender.stringValue
        model.selectedID = model.filtered.first?.id
    }

    @objc private func selectSymbol(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              rawValue.hasPrefix("symbol.") else { return }
        model.symbol = String(rawValue.dropFirst("symbol.".count))
    }

    @objc private func selectColor(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              rawValue.hasPrefix("color.") else { return }
        model.color = String(rawValue.dropFirst("color.".count))
    }

    @objc private func activateSelected(_ sender: NSTableView) {
        let row = sender.selectedRow
        guard model.filtered.indices.contains(row) else { return }
        model.activate(model.filtered[row].id)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === queryField {
            model.query = queryField.stringValue
            model.selectedID = model.filtered.first?.id
        } else if field === nameField {
            model.name = nameField.stringValue
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if textView.hasMarkedText() { return false }
        switch NSStringFromSelector(commandSelector) {
        case "insertNewline:" where control === nameField:
            model.save()
        case "moveUp:" where control === queryField:
            model.step(-1)
        case "moveDown:" where control === queryField:
            model.step(1)
        case "insertNewline:" where control === queryField:
            model.activateSelected()
        case "cancelOperation:":
            model.cancel()
        default:
            return false
        }
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { lastRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard lastRows.indices.contains(row),
              let workspace = model.store.workspaces.first(where: { $0.id == lastRows[row].id }) else { return nil }
        let snapshot = lastRows[row]
        let identifier = NSUserInterfaceItemIdentifier("workspace.row")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? TerminalWorkspaceRowCell
            ?? TerminalWorkspaceRowCell()
        cell.identifier = identifier
        let actions = TerminalWorkspaceRowActions(
            open: { [weak self] in self?.model.activate(workspace.id) },
            edit: { [weak self] in self?.model.beginEdit(workspace.id) },
            delete: { [weak self] in self?.model.beginDelete(workspace.id) }
        )
        cell.configure(
            workspace: workspace,
            snapshot: snapshot,
            moving: model.page == .move,
            actions: actions
        )
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        TerminalWorkspaceSelectionRow()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection else { return }
        let row = table.selectedRow
        model.selectedID = model.filtered.indices.contains(row) ? model.filtered[row].id : nil
    }

    private func syncSelection() {
        isSyncingSelection = true
        if let id = model.selectedID,
           let row = model.filtered.firstIndex(where: { $0.id == id }) {
            if table.selectedRow != row {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                table.scrollRowToVisible(row)
            }
        } else {
            if table.selectedRow >= 0 { table.deselectAll(nil) }
        }
        isSyncingSelection = false
    }

    private func shortcut(for id: UUID) -> String? {
        guard model.page != .move,
              let index = model.store.workspaces.firstIndex(where: { $0.id == id }),
              index < 9 else { return nil }
        return OMGKeyboardShortcut(storageValue: model.store.shortcut(slot: index + 1))?.displayValue
    }

    private func focusPage() {
        switch model.page {
        case .switcher, .move: view.window?.makeFirstResponder(queryField)
        case .create, .edit: view.window?.makeFirstResponder(nameField)
        case .delete: view.window?.makeFirstResponder(cancelButton)
        }
    }
}

@MainActor
private final class TerminalWorkspaceTableView: NSTableView {
    var onEscape: (() -> Void)?
    var onMove: ((Int) -> Void)?
    var onActivate: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: onMove?(-1)
        case 125: onMove?(1)
        case 36, 76: onActivate?()
        case 53: onEscape?()
        default: super.keyDown(with: event)
        }
    }
}

private final class TerminalWorkspaceSelectionRow: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()
    }
}

@MainActor
private final class TerminalWorkspaceHitTargetButton: NSButton {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview, bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }
}

@MainActor
private final class TerminalWorkspaceRowCell: NSTableCellView {
    private let openButton = TerminalWorkspaceHitTargetButton()
    private let symbol = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let trailing = NSTextField(labelWithString: "")
    private let editButton = NSButton()
    private let deleteButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        openButton.title = ""
        openButton.isBordered = false
        openButton.setButtonType(.momentaryPushIn)
        openButton.alignment = .left
        symbol.imageScaling = .scaleProportionallyDown
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        trailing.font = .systemFont(ofSize: 10)
        trailing.textColor = .secondaryLabelColor
        editButton.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        [editButton, deleteButton].forEach {
            $0.bezelStyle = .toolbar
            $0.setAccessibilityRole(.button)
        }
        let labels = NSStackView(views: [title, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        let content = NSStackView(views: [symbol, labels, NSView(), trailing])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        let actions = NSStackView(views: [editButton, deleteButton])
        actions.orientation = .horizontal
        actions.spacing = 2
        let row = NSStackView(views: [openButton, actions])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        openButton.addSubview(content)
        NSLayoutConstraint.activate([
            symbol.widthAnchor.constraint(equalToConstant: 28),
            symbol.heightAnchor.constraint(equalToConstant: 28),
            editButton.widthAnchor.constraint(equalToConstant: 24),
            deleteButton.widthAnchor.constraint(equalToConstant: 24),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            content.leadingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: 6),
            content.trailingAnchor.constraint(equalTo: openButton.trailingAnchor, constant: -4),
            content.topAnchor.constraint(equalTo: openButton.topAnchor),
            content.bottomAnchor.constraint(equalTo: openButton.bottomAnchor),
        ])
        openButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        workspace: TerminalWorkspace,
        snapshot: TerminalWorkspaceRowSnapshot,
        moving: Bool,
        actions: TerminalWorkspaceRowActions
    ) {
        symbol.image = NSImage(systemSymbolName: workspace.symbol, accessibilityDescription: nil)
        symbol.contentTintColor = NSColor(workspace.tint)
        title.stringValue = workspace.name
        subtitle.stringValue = snapshot.tabCount == 0
            ? WorkspaceL10n.text("Not open in this window", "当前窗口未打开")
            : WorkspaceL10n.text("\(snapshot.tabCount) tabs in this window", "当前窗口 · \(snapshot.tabCount) 个标签")
        trailing.stringValue = snapshot.isCurrent
            ? WorkspaceL10n.text("Current", "当前")
            : moving ? "→" : snapshot.shortcut ?? ""
        editButton.isHidden = moving
        deleteButton.isHidden = moving
        editButton.isEnabled = snapshot.actionsEnabled
        deleteButton.isEnabled = snapshot.canDelete && snapshot.actionsEnabled
        editButton.setAccessibilityLabel(WorkspaceL10n.text("Edit \(workspace.name)", "编辑 \(workspace.name)"))
        deleteButton.setAccessibilityLabel(WorkspaceL10n.text("Delete \(workspace.name)", "删除 \(workspace.name)"))
        editButton.setAccessibilityIdentifier("workspace.edit.\(workspace.id)")
        deleteButton.setAccessibilityIdentifier("workspace.delete.\(workspace.id)")
        openButton.setAccessibilityLabel(workspace.name)
        openButton.setAccessibilityIdentifier("workspace.open.\(workspace.id)")
        openButton.isEnabled = snapshot.actionsEnabled
        openButton.target = self
        openButton.action = #selector(openRow)
        editButton.target = self
        editButton.action = #selector(editRow)
        deleteButton.target = self
        deleteButton.action = #selector(deleteRow)
        self.open = actions.open
        self.edit = actions.edit
        self.delete = actions.delete
    }

    private var open: (() -> Void)?
    private var edit: (() -> Void)?
    private var delete: (() -> Void)?

    @objc private func openRow() { open?() }
    @objc private func editRow() { edit?() }
    @objc private func deleteRow() { delete?() }
}
