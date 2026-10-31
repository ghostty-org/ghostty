import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GitCommitAIRoutesTable: NSViewRepresentable {
    @ObservedObject var settings: OhMyGhosttySettings

    func makeCoordinator() -> Coordinator {
        Coordinator(settings: settings)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 40
        table.intercellSpacing = .zero
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.draggingDestinationFeedbackStyle = .gap
        table.registerForDraggedTypes([.string])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setAccessibilityIdentifier("git.commit-ai.routes")

        let column = NSTableColumn(identifier: .init("route"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        scrollView.documentView = table
        context.coordinator.tableView = table
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.settings = settings
        context.coordinator.tableView?.reloadData()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var settings: OhMyGhosttySettings
        weak var tableView: NSTableView?

        init(settings: OhMyGhosttySettings) {
            self.settings = settings
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            settings.gitCommitAIRoutes.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard settings.gitCommitAIRoutes.indices.contains(row) else { return nil }
            let route = settings.gitCommitAIRoutes[row]
            let cell = tableView.makeView(
                withIdentifier: .init("git.commit-ai.route-cell"),
                owner: self
            ) as? GitCommitAIRouteCell ?? GitCommitAIRouteCell()
            cell.identifier = .init("git.commit-ai.route-cell")
            cell.configure(route: route, settings: settings)
            return cell
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard settings.gitCommitAIRoutes.indices.contains(row) else { return nil }
            return settings.gitCommitAIRoutes[row].id.uuidString as NSString
        }

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation operation: NSTableView.DropOperation
        ) -> NSDragOperation {
            guard operation == .above,
                  info.draggingSourceOperationMask.contains(.move),
                  info.draggingPasteboard.string(forType: .string).flatMap(UUID.init(uuidString:)) != nil else {
                return []
            }
            return .move
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            guard let rawID = info.draggingPasteboard.string(forType: .string),
                  let id = UUID(uuidString: rawID),
                  let source = settings.gitCommitAIRoutes.firstIndex(where: { $0.id == id }) else {
                return false
            }
            let routes = Self.moved(settings.gitCommitAIRoutes, routeID: id, toInsertionRow: row)
            guard routes != settings.gitCommitAIRoutes else { return true }
            settings.gitCommitAIRoutes = routes
            tableView.reloadData()
            return routes.indices.contains(source)
        }

        @discardableResult
        func move(_ id: UUID, by delta: Int) -> Bool {
            guard let source = settings.gitCommitAIRoutes.firstIndex(where: { $0.id == id }),
                  settings.gitCommitAIRoutes.indices.contains(source + delta) else { return false }
            settings.gitCommitAIRoutes.swapAt(source, source + delta)
            tableView?.reloadData()
            return true
        }

        func remove(_ id: UUID) {
            settings.gitCommitAIRoutes.removeAll { $0.id == id }
            tableView?.reloadData()
        }

        static func moved(_ routes: [GitCommitAIRoute], routeID: UUID, toInsertionRow row: Int) -> [GitCommitAIRoute] {
            guard let source = routes.firstIndex(where: { $0.id == routeID }) else { return routes }
            let insertion = min(max(row, 0), routes.count)
            let destination = insertion > source ? insertion - 1 : insertion
            guard destination != source else { return routes }
            var result = routes
            let route = result.remove(at: source)
            result.insert(route, at: min(destination, result.count))
            return result
        }
    }
}

@MainActor
private final class GitCommitAIRouteCell: NSTableCellView {
    private let reorderIcon = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let upButton = NSButton()
    private let downButton = NSButton()
    private let removeButton = NSButton()
    private weak var settings: OhMyGhosttySettings?
    private var routeID: UUID?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        reorderIcon.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)
        reorderIcon.contentTintColor = .secondaryLabelColor
        reorderIcon.setAccessibilityLabel(GitL10n.text("Reorder model"))
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configure(upButton, symbol: "arrow.up", label: GitL10n.text("Move up"), action: #selector(moveRouteUp))
        configure(downButton, symbol: "arrow.down", label: GitL10n.text("Move down"), action: #selector(moveRouteDown))
        configure(removeButton, symbol: "minus.circle", label: GitL10n.text("Remove model"), action: #selector(removeRoute))
        let row = NSStackView(views: [reorderIcon, titleField, upButton, downButton, removeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            reorderIcon.widthAnchor.constraint(equalToConstant: 15),
            titleField.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            upButton.widthAnchor.constraint(equalToConstant: 24),
            downButton.widthAnchor.constraint(equalToConstant: 24),
            removeButton.widthAnchor.constraint(equalToConstant: 24),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(route: GitCommitAIRoute, settings: OhMyGhosttySettings) {
        self.routeID = route.id
        self.settings = settings
        titleField.stringValue = route.title
        let routes = settings.gitCommitAIRoutes
        guard let index = routes.firstIndex(where: { $0.id == route.id }) else { return }
        upButton.isEnabled = index > routes.startIndex
        downButton.isEnabled = routes.index(after: index) < routes.endIndex
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.bezelStyle = .accessoryBar
        button.isBordered = false
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier("git.commit-ai.\(symbol)")
    }

    @objc private func moveRouteUp() { applyMove(-1) }
    @objc private func moveRouteDown() { applyMove(1) }

    private func applyMove(_ delta: Int) {
        guard let routeID,
              let table = superview?.superview as? NSTableView,
              let coordinator = table.dataSource as? GitCommitAIRoutesTable.Coordinator else { return }
        coordinator.move(routeID, by: delta)
    }

    @objc private func removeRoute() {
        guard let routeID,
              let table = superview?.superview as? NSTableView,
              let coordinator = table.dataSource as? GitCommitAIRoutesTable.Coordinator else { return }
        coordinator.remove(routeID)
    }
}

@MainActor
enum GitCommitAISettingsPanel {
    static func presentPrompt(settings: OhMyGhosttySettings, from parent: NSWindow?) {
        guard let parent else { return }
        present(
            GitCommitAIPromptController(prompt: settings.gitCommitAIPrompt) { settings.gitCommitAIPrompt = $0 },
            title: GitL10n.text("Custom commit prompt"),
            size: NSSize(width: 560, height: 440),
            from: parent
        )
    }

    static func presentAddModels(settings: OhMyGhosttySettings, from parent: NSWindow?) {
        guard let parent else { return }
        present(
            GitCommitAIAddModelsController { agent, models in
                settings.gitCommitAIRoutes = GitCommitAIRoute.adding(
                    agent: agent, models: models, to: settings.gitCommitAIRoutes
                )
            },
            title: GitL10n.text("Add Agent Models…"),
            size: NSSize(width: 520, height: 620),
            from: parent
        )
    }

    private static func present(_ controller: GitCommitSettingsPanelController,
                                title: String, size: NSSize, from parent: NSWindow) {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .closable],
                            backing: .buffered,
                            defer: false)
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.appearance = parent.appearance ?? NSApp.effectiveAppearance
        let palette = OMGThemeBackground.palette(for: parent)
        panel.backgroundColor = palette.background
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = true
        panel.contentViewController = controller
        (controller.view as? OMGNativeSurfaceView)?.bindTheme(to: parent)
        parent.beginSheet(panel) { _ in controller.sheetEnded() }
    }
}

@MainActor
class GitCommitSettingsPanelController: NSViewController, NSWindowDelegate {
    private(set) var finished = false
    private weak var panelWindow: NSWindow?

    override func viewDidAppear() {
        super.viewDidAppear()
        panelWindow = view.window
        panelWindow?.delegate = self
    }

    func closePanel() {
        guard !finished else { return }
        finished = true
        guard let window = panelWindow ?? view.window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.orderOut(nil)
        }
    }

    func sheetEnded() {
        finished = true
        let panel = panelWindow ?? view.window
        panel?.orderOut(nil)
        panel?.contentViewController = nil
        panelWindow = nil
        didEndSheet()
    }

    func didEndSheet() {}

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closePanel()
        return false
    }
}

@MainActor
final class GitCommitAIPromptController: GitCommitSettingsPanelController, NSTextViewDelegate {
    private var prompt: String
    private let save: (String) -> Void
    let promptView = NSTextView()
    let saveButton = NSButton()

    init(prompt: String, save: @escaping (String) -> Void) {
        self.prompt = prompt
        self.save = save
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = OMGNativeSurfaceView()
        let title = NSTextField(labelWithString: GitL10n.text("Custom commit prompt"))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        promptView.isRichText = false
        promptView.allowsUndo = true
        promptView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        promptView.string = prompt
        promptView.delegate = self
        promptView.setAccessibilityLabel(GitL10n.text("Custom commit prompt"))
        promptView.isVerticallyResizable = true
        promptView.isHorizontallyResizable = false
        promptView.autoresizingMask = [.width]
        promptView.textContainer?.widthTracksTextView = true
        promptView.textContainer?.containerSize = NSSize(width: 520, height: CGFloat.greatestFiniteMagnitude)
        promptView.minSize = .zero
        promptView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                    height: CGFloat.greatestFiniteMagnitude)
        promptView.frame = NSRect(x: 0, y: 0, width: 520, height: 250)
        scroll.documentView = promptView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let help = NSTextField(wrappingLabelWithString: GitL10n.text(
            "Specify language, format and commit style. Applied to all models, including fallbacks. Leave empty to follow recent commits."
        ))
        help.textColor = .secondaryLabelColor
        help.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let cancel = NSButton(title: GitL10n.text("Cancel"), target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.keyEquivalentModifierMask = []
        saveButton.title = GitL10n.text("Save")
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(savePrompt)
        saveButton.setAccessibilityIdentifier("git.commit-ai.prompt.save")
        let actions = NSStackView(views: [NSView(), cancel, saveButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [title, scroll, help, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 250),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(promptView)
    }

    func textDidChange(_ notification: Notification) {
        guard let editor = notification.object as? NSTextView, editor === promptView else { return }
        prompt = editor.string
    }

    @objc private func cancel() { closePanel() }

    @objc private func savePrompt() {
        save(promptView.string)
        closePanel()
    }
}

@MainActor
final class GitCommitAIAddModelsController: GitCommitSettingsPanelController,
    NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let add: (GitCommitAgent, [String]) -> Void
    private let agentPicker = NSPopUpButton()
    private let searchField = NSSearchField()
    private let modelTable = NSTableView()
    private let tableScroll = NSScrollView()
    private let spinner = NativeProgressIndicator()
    private let reloadButton = NSButton()
    private let updateButton = NSButton()
    private let updateStatus = NSTextField(wrappingLabelWithString: "")
    private let errorField = NSTextField(wrappingLabelWithString: "")
    private let helpButton = NSButton()
    private let helpField = NSTextField(wrappingLabelWithString: "")
    private let addButton = NSButton()
    private var agent = GitCommitAgent.claude
    private var query = ""
    private var models: [String] = []
    private var selected: Set<String> = []
    private var loading = false
    private var loadingID = UUID()
    private var updateInfo: GitACPAdapterUpdateInfo?
    private var checkingUpdate = false
    private var updating = false
    private var reloadTask: Task<Void, Never>?

    init(add: @escaping (GitCommitAgent, [String]) -> Void) {
        self.add = add
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = OMGNativeSurfaceView()
        let title = NSTextField(labelWithString: GitL10n.text("Add Agent Models…"))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        agentPicker.removeAllItems()
        for value in GitCommitAgent.allCases {
            agentPicker.addItem(withTitle: value.title)
            agentPicker.lastItem?.representedObject = value.rawValue
        }
        agentPicker.target = self
        agentPicker.action = #selector(agentChanged)
        agentPicker.setAccessibilityLabel(GitL10n.text("Agent"))

        let top = NSStackView(views: [
            NSTextField(labelWithString: GitL10n.text("Agent")), agentPicker, spinner
        ])
        top.orientation = .horizontal
        top.spacing = 8
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let listHeader = NSStackView(views: [
            NSTextField(labelWithString: GitL10n.text("Available models")),
            NSView(),
            updateButton,
            reloadButton
        ])
        listHeader.orientation = .horizontal
        listHeader.alignment = .centerY
        listHeader.spacing = 8
        updateButton.target = self
        updateButton.action = #selector(confirmUpdate)
        updateButton.bezelStyle = .rounded
        updateButton.isHidden = true
        reloadButton.target = self
        reloadButton.action = #selector(reload)
        reloadButton.bezelStyle = .rounded
        reloadButton.title = GitL10n.text("Reload")
        reloadButton.setAccessibilityIdentifier("git.commit-ai.models.reload")

        searchField.placeholderString = GitL10n.text("Search models…")
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel(GitL10n.text("Search models…"))
        searchField.setAccessibilityIdentifier("git.commit-ai.models.search")

        let column = NSTableColumn(identifier: .init("model"))
        column.resizingMask = .autoresizingMask
        modelTable.addTableColumn(column)
        modelTable.headerView = nil
        modelTable.rowHeight = 28
        modelTable.intercellSpacing = .zero
        modelTable.selectionHighlightStyle = .none
        modelTable.dataSource = self
        modelTable.delegate = self
        modelTable.setAccessibilityLabel(GitL10n.text("Available models"))
        tableScroll.documentView = modelTable
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.borderType = .bezelBorder
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        updateStatus.textColor = .secondaryLabelColor
        updateStatus.maximumNumberOfLines = 2
        errorField.textColor = .systemRed
        errorField.maximumNumberOfLines = 3
        helpButton.title = GitL10n.text("About AI generation")
        helpButton.bezelStyle = .disclosure
        helpButton.target = self
        helpButton.action = #selector(toggleHelp)
        helpField.stringValue = GitL10n.text(
            "Models run through local ACP, including for SSH repositories. Selected services receive the changes. Sessions expire after 30 days."
        )
        helpField.textColor = .secondaryLabelColor
        helpField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        helpField.maximumNumberOfLines = 0
        helpField.isHidden = true
        let cancelButton = NSButton(title: GitL10n.text("Cancel"), target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.keyEquivalentModifierMask = []
        addButton.title = GitL10n.text("Add")
        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addSelected)
        addButton.keyEquivalent = "\r"
        addButton.setAccessibilityIdentifier("git.commit-ai.models.add")
        let actions = NSStackView(views: [NSView(), cancelButton, addButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [title, top, listHeader, searchField, tableScroll,
                                       updateStatus, errorField, helpButton, helpField, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor),
            agentPicker.widthAnchor.constraint(equalToConstant: 300),
            listHeader.widthAnchor.constraint(equalTo: stack.widthAnchor),
            searchField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tableScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            tableScroll.heightAnchor.constraint(lessThanOrEqualToConstant: 260),
            updateStatus.widthAnchor.constraint(equalTo: stack.widthAnchor),
            errorField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            helpButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            helpField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = root
        updateButtons()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
        if reloadTask == nil { loadModels() }
    }

    deinit { reloadTask?.cancel() }

    override func windowShouldClose(_ sender: NSWindow) -> Bool {
        reloadTask?.cancel()
        return super.windowShouldClose(sender)
    }

    override func didEndSheet() {
        reloadTask?.cancel()
    }

    private var visibleModels: [String] {
        models.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleModels.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleModels.indices.contains(row) else { return nil }
        let model = visibleModels[row]
        let identifier = NSUserInterfaceItemIdentifier("git.commit-ai.model-cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? GitCommitAIModelCell
            ?? GitCommitAIModelCell()
        cell.identifier = identifier
        cell.configure(title: model, checked: selected.contains(model), row: row, target: self,
                       action: #selector(toggleModel(_:)))
        return cell
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === searchField else { return }
        query = searchField.stringValue
        modelTable.reloadData()
    }

    @objc private func toggleModel(_ sender: NSButton) {
        guard visibleModels.indices.contains(sender.tag) else { return }
        let model = visibleModels[sender.tag]
        if !selected.insert(model).inserted { selected.remove(model) }
        modelTable.reloadData()
        updateButtons()
    }

    @objc private func agentChanged() {
        guard let raw = agentPicker.selectedItem?.representedObject as? String,
              let value = GitCommitAgent(rawValue: raw), value != agent else { return }
        agent = value
        selected = []
        query = ""
        models = []
        searchField.stringValue = ""
        updateInfo = nil
        errorField.stringValue = ""
        updateStatus.stringValue = ""
        modelTable.reloadData()
        loadModels()
    }

    @objc private func reload() { loadModels() }

    private func loadModels() {
        reloadTask?.cancel()
        let requestedAgent = agent
        let id = UUID()
        loadingID = id
        loading = true
        checkingUpdate = false
        errorField.stringValue = ""
        spinner.setAnimating(true)
        updateButtons()
        reloadTask = Task { @MainActor in
            defer {
                if loadingID == id {
                    loading = false
                    spinner.setAnimating(false)
                    reloadTask = nil
                    updateButtons()
                }
            }
            do {
                let result = try await GitCommitAIService.models(agent: requestedAgent)
                guard !finished, !Task.isCancelled, loadingID == id, agent == requestedAgent else { return }
                models = result
                selected.formIntersection(Set(result))
                modelTable.reloadData()
                if result.isEmpty {
                    errorField.stringValue = GitL10n.text("No models found. Check the local ACP adapter and login.")
                }
            } catch {
                guard !finished, !Task.isCancelled, loadingID == id, agent == requestedAgent else { return }
                errorField.stringValue = error.localizedDescription
                return
            }

            guard requestedAgent == .codex, !finished, !Task.isCancelled,
                  loadingID == id, agent == requestedAgent else { return }
            checkingUpdate = true
            updateStatus.stringValue = GitL10n.text("Checking for Codex ACP updates…")
            updateButtons()
            do {
                let result = try await GitACPAdapterManager.checkCodexUpdate()
                guard !finished, !Task.isCancelled, loadingID == id, agent == requestedAgent else { return }
                updateInfo = result
                updateStatus.stringValue = updateInfo.flatMap { info in
                    info.updateAvailable
                        ? GitL10n.format("Codex ACP update available: {0} (installed: {1}).",
                                         info.latestVersion, info.installedVersion ?? GitL10n.text("not detected"))
                        : GitL10n.format("Codex ACP is up to date ({0}).", info.latestVersion)
                } ?? ""
            } catch {
                guard !finished, !Task.isCancelled, loadingID == id, agent == requestedAgent else { return }
                updateStatus.stringValue = GitL10n.text(
                    "Could not check the Codex ACP version. Model loading is unaffected."
                )
            }
            checkingUpdate = false
            updateButtons()
        }
    }

    @objc private func confirmUpdate() {
        guard let info = updateInfo, info.updateAvailable, let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = GitL10n.text("Update Codex ACP for OMG?")
        alert.informativeText = GitL10n.text(
            "OMG will install this stable Codex ACP version in its own Application Support folder. Your global npm installation will not be changed."
        )
        alert.addButton(withTitle: GitL10n.text("Update and reload"))
        alert.addButton(withTitle: GitL10n.text("Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in await self?.updateCodexAndReload(version: info.latestVersion) }
        }
    }

    private func updateCodexAndReload(version: String) async {
        guard agent == .codex, !updating else { return }
        updating = true
        loading = true
        errorField.stringValue = ""
        spinner.setAnimating(true)
        updateButtons()
        defer {
            updating = false
            loading = false
            spinner.setAnimating(false)
            updateButtons()
        }
        do {
            try await GitACPAdapterManager.installCodex(version: version)
            let refreshed = try await GitCommitAIService.models(agent: .codex)
            guard agent == .codex else { return }
            updateInfo = try? await GitACPAdapterManager.checkCodexUpdate()
            if refreshed.isEmpty {
                errorField.stringValue = GitL10n.text(
                    "Codex ACP was updated, but no models were returned. The previous model list was kept."
                )
            } else {
                models = refreshed
                selected.formIntersection(Set(refreshed))
                updateStatus.stringValue = GitL10n.format("Codex ACP {0} updated; models reloaded.", version)
                modelTable.reloadData()
            }
        } catch {
            errorField.stringValue = GitL10n.format(
                "Could not update or reload Codex ACP. The previous model list was kept: {0}",
                error.localizedDescription
            )
        }
    }

    private func updateButtons() {
        guard isViewLoaded else { return }
        agentPicker.isEnabled = !updating
        searchField.isEnabled = !updating
        modelTable.isEnabled = !updating
        reloadButton.isEnabled = !loading && !updating
        addButton.isEnabled = !loading && !updating &&
            !GitCommitAIRoute.adding(agent: agent, models: Array(selected), to: []).isEmpty
        if let updateInfo {
            updateButton.isHidden = agent != .codex || !updateInfo.updateAvailable
            updateButton.title = GitL10n.text(updateInfo.installedVersion == nil ? "Install for OMG…" : "Update for OMG…")
            updateButton.isEnabled = !loading && !updating && !checkingUpdate
        } else {
            updateButton.isHidden = true
            updateButton.isEnabled = false
        }
    }

    @objc private func toggleHelp() {
        helpField.isHidden.toggle()
        helpButton.image = NSImage(
            systemSymbolName: helpField.isHidden ? "chevron.right" : "chevron.down",
            accessibilityDescription: nil
        )
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    @objc private func cancel() {
        reloadTask?.cancel()
        closePanel()
    }

    @objc private func addSelected() {
        let routes = GitCommitAIRoute.adding(agent: agent, models: models.filter(selected.contains), to: [])
        guard !routes.isEmpty, !loading, !updating else { return }
        add(agent, routes.map(\.model))
        closePanel()
    }

}

@MainActor
private final class GitCommitAIModelCell: NSTableCellView {
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.font = .systemFont(ofSize: NSFont.systemFontSize)
        addSubview(checkbox)
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            checkbox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, checked: Bool, row: Int, target: AnyObject, action: Selector) {
        checkbox.title = title
        checkbox.state = checked ? .on : .off
        checkbox.target = target
        checkbox.action = action
        checkbox.tag = row
    }
}
