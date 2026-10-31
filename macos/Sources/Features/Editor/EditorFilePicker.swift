import AppKit
import Combine

@MainActor
final class EditorFilePicker: NSWindowController {
    private let parentWindow: NSWindow
    private let onOpen: (String) -> Void
    private let model: EditorFilePickerModel

    static func present(
        filesystem: any WorkspaceFilesystem,
        for parentWindow: NSWindow,
        onOpen: @escaping (String) -> Void
    ) {
        let picker = EditorFilePicker(
            filesystem: filesystem,
            parentWindow: parentWindow,
            onOpen: onOpen
        )
        guard let window = picker.window else { return }
        parentWindow.beginSheet(window) { _ in
            picker.model.cancelLoading()
        }
    }

    private init(
        filesystem: any WorkspaceFilesystem,
        parentWindow: NSWindow,
        onOpen: @escaping (String) -> Void
    ) {
        self.parentWindow = parentWindow
        self.onOpen = onOpen
        let model = EditorFilePickerModel(filesystem: filesystem)
        self.model = model
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "Open File — \(filesystem.descriptor.displayName)"
        super.init(window: panel)
        let content = EditorFilePickerController(
                model: model,
                onCancel: { [weak self] in self?.finish() },
                onOpen: { [weak self] path in self?.finish(opening: path) }
        )
        panel.contentViewController = content
        (content.view as? OMGNativeSurfaceView)?.bindTheme(to: parentWindow)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func finish(opening path: String? = nil) {
        guard let window else { return }
        model.cancelLoading()
        parentWindow.endSheet(window)
        if let path { onOpen(path) }
    }
}

@MainActor
final class EditorFilePickerModel: ObservableObject {
    @Published private(set) var directory: String
    @Published var pathInput: String = ""
    @Published private(set) var entries: [WorkspaceFileEntry] = []
    @Published var selection: String?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    let filesystem: any WorkspaceFilesystem
    private var loadTask: Task<Void, Never>?

    init(filesystem: any WorkspaceFilesystem) {
        self.filesystem = filesystem
        let initialDir = filesystem.descriptor.workingDirectory
        self.directory = initialDir
        self.pathInput = initialDir
        load(initialDir)
    }

    var selectedEntry: WorkspaceFileEntry? {
        entries.first { $0.path == selection }
    }

    var canGoUp: Bool { directory != "/" }

    func open(_ entry: WorkspaceFileEntry, fileHandler: (String) -> Void) {
        if entry.isDirectory {
            load(entry.path)
        } else {
            fileHandler(entry.path)
        }
    }

    func goUp() {
        guard canGoUp else { return }
        let parent = (directory as NSString).deletingLastPathComponent
        load(parent.isEmpty ? "/" : parent)
    }

    func retry() {
        load(directory)
    }

    func navigate(to input: String, fileHandler: @escaping (String) -> Void) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let target: String
        if trimmed.hasPrefix("/") {
            target = (trimmed as NSString).standardizingPath
        } else {
            target = ((directory as NSString).appendingPathComponent(trimmed) as NSString).standardizingPath
        }
        if let file = entries.first(where: { $0.path == target && !$0.isDirectory }) {
            fileHandler(file.path)
            return
        }
        if let dir = entries.first(where: { $0.path == target && $0.isDirectory }) {
            load(dir.path)
            return
        }
        directory = target
        pathInput = target
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        loadTask = Task { @MainActor in
            if let type = try? await filesystem.itemType(at: target) {
                guard !Task.isCancelled, directory == target else { return }
                if type == .file {
                    isLoading = false
                    fileHandler(target)
                    return
                }
            }
            guard !Task.isCancelled, directory == target else { return }
            load(target)
        }
    }

    func openSelection(fileHandler: (String) -> Void) {
        guard let selectedEntry else { return }
        open(selectedEntry, fileHandler: fileHandler)
    }

    func cancelLoading() {
        loadTask?.cancel()
        loadTask = nil
    }

    private func load(_ path: String) {
        loadTask?.cancel()
        directory = path
        pathInput = path
        entries = []
        selection = nil
        isLoading = true
        errorMessage = nil
        loadTask = Task {
            do {
                let result = try await filesystem.listDirectory(at: path)
                guard !Task.isCancelled, directory == path else { return }
                entries = result
            } catch {
                guard !Task.isCancelled, directory == path else { return }
                entries = []
                errorMessage = error.localizedDescription
            }
            guard !Task.isCancelled, directory == path else { return }
            isLoading = false
        }
    }
}

@MainActor
final class EditorFilePickerController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let model: EditorFilePickerModel
    let onCancel: () -> Void
    let onOpen: (String) -> Void
    let pathField = OMGNativeTextField()
    let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NativeProgressIndicator()
    private let goUpButton = NativeActionControl()
    private let retryButton = NativeActionControl()
    private let openButton = NativeActionControl()
    private var cancellables = Set<AnyCancellable>()
    private var isSynchronizingSelection = false
    private var renderedEntries: [WorkspaceFileEntry] = []
    private var renderedDirectory: String?

    init(model: EditorFilePickerModel, onCancel: @escaping () -> Void, onOpen: @escaping (String) -> Void) {
        self.model = model
        self.onCancel = onCancel
        self.onOpen = onOpen
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = OMGNativeSurfaceView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setFrameSize(NSSize(width: 640, height: 460))
        view = root

        let pathBar = NSStackView()
        pathBar.orientation = .horizontal
        pathBar.spacing = 8
        pathBar.translatesAutoresizingMaskIntoConstraints = false
        goUpButton.title = ""
        retryButton.title = "Retry"
        retryButton.controlStyle = .bordered
        openButton.title = "Open"
        openButton.controlStyle = .prominent
        goUpButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Parent Directory")
        goUpButton.bezelStyle = .toolbar
        goUpButton.target = self
        goUpButton.action = #selector(goUp)
        goUpButton.setAccessibilityLabel("Parent Directory")
        pathField.placeholderString = "Path"
        pathField.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        pathField.delegate = self
        pathBar.addArrangedSubview(goUpButton)
        pathBar.addArrangedSubview(pathField)
        pathField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        pathBar.addArrangedSubview(spinner)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.intercellSpacing = .zero
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        scrollView.drawsBackground = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelection)
        tableView.setAccessibilityLabel("Files")
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.alignment = .center
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 0
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        retryButton.target = self
        retryButton.action = #selector(retry)
        retryButton.isHidden = true

        let cancelButton = NativeActionControl()
        cancelButton.title = "Cancel"
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.controlStyle = .bordered
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.keyEquivalentModifierMask = []
        cancelButton.bezelStyle = .rounded
        openButton.target = self
        openButton.action = #selector(openSelection)
        openButton.keyEquivalent = "\r"
        openButton.bezelStyle = .rounded
        openButton.keyEquivalentModifierMask = []

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [retryButton, spacer, cancelButton, openButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(pathBar)
        root.addSubview(scrollView)
        root.addSubview(statusLabel)
        root.addSubview(buttons)
        NSLayoutConstraint.activate([
            pathBar.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            pathBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            pathBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scrollView.topAnchor.constraint(equalTo: pathBar.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: pathBar.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: pathBar.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            statusLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -20),
            buttons.leadingAnchor.constraint(equalTo: pathBar.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: pathBar.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        bindModel()
        render()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(tableView)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { renderedEntries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("entry-cell")
        guard renderedEntries.indices.contains(row) else { return nil }
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? EditorFilePickerCell
            ?? EditorFilePickerCell()
        cell.identifier = identifier
        cell.configure(renderedEntries[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSynchronizingSelection else { return }
        let row = tableView.selectedRow
        model.selection = renderedEntries.indices.contains(row) ? renderedEntries[row].path : nil
        renderButtons()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === pathField else { return }
        model.pathInput = pathField.stringValue
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === pathField else { return }
        model.pathInput = field.stringValue
        let movement = notification.userInfo?["NSTextMovement"] as? Int
        guard movement == NSReturnTextMovement else { return }
        model.navigate(to: field.stringValue, fileHandler: onOpen)
    }

    private func bindModel() {
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.render() }
            }
            .store(in: &cancellables)
    }

    private func render() {
        guard isViewLoaded else { return }
        let navigated = renderedDirectory != model.directory
        renderedDirectory = model.directory
        if navigated || pathField.currentEditor() == nil, pathField.stringValue != model.pathInput {
            pathField.stringValue = model.pathInput
        }
        goUpButton.isEnabled = model.canGoUp && !model.isLoading
        if model.isLoading { spinner.setAnimating(true) } else { spinner.setAnimating(false) }
        let entriesChanged = renderedEntries != model.entries
        isSynchronizingSelection = true
        if entriesChanged {
            renderedEntries = model.entries
            tableView.reloadData()
        }
        if let selection = model.selection,
           let row = model.entries.firstIndex(where: { $0.path == selection }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        isSynchronizingSelection = false
        renderStatus()
        renderButtons()
    }

    private func renderStatus() {
        if let error = model.errorMessage {
            statusLabel.stringValue = "Could Not Open Directory\n\(error)"
            statusLabel.isHidden = false
            retryButton.isHidden = false
            scrollView.isHidden = true
        } else if model.isLoading {
            statusLabel.stringValue = "Loading…"
            statusLabel.isHidden = false
            retryButton.isHidden = true
            scrollView.isHidden = true
        } else if model.entries.isEmpty {
            statusLabel.stringValue = "This directory is empty."
            statusLabel.isHidden = false
            retryButton.isHidden = true
            scrollView.isHidden = true
        } else {
            statusLabel.isHidden = true
            retryButton.isHidden = true
            scrollView.isHidden = false
        }
    }

    private func renderButtons() {
        openButton.isEnabled = model.selectedEntry != nil && !model.isLoading
    }

    @objc private func goUp() { model.goUp() }
    @objc private func retry() { model.retry() }
    @objc func cancel() { onCancel() }
    @objc func openSelection() {
        guard !model.isLoading else { return }
        model.openSelection(fileHandler: onOpen)
    }
}

private final class EditorFilePickerCell: NSTableCellView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let icon = NSImageView()
        let label = NSTextField(labelWithString: "")
        icon.contentTintColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ entry: WorkspaceFileEntry) {
        imageView?.image = NSImage(systemSymbolName: entry.isDirectory ? "folder" : "doc",
                                  accessibilityDescription: nil)
        textField?.stringValue = entry.name
        toolTip = entry.path
    }
}
