import AppKit
import Combine
import Foundation
import GhosttyKit

struct SessionRuntimeLibraryStrings: Equatable, Sendable {
    private let settings: SettingsStrings

    init(language: OhMyGhosttyLanguage) {
        settings = SettingsStrings(language: language)
    }

    func t(_ english: String, _ chinese: String) -> String {
        settings.t(english, chinese)
    }

    var windowTitle: String { t("Session Library", "会话库") }
    var endpointsHeader: String { t("ENDPOINTS", "连接目标") }
    var sessionsTitle: String { t("Sessions", "会话") }
    var refresh: String { t("Refresh", "刷新") }
    var cancel: String { t("Cancel", "取消") }
    var openExisting: String { t("Open Existing", "打开现有会话") }
    var endSession: String { t("End Session…", "结束会话…") }
    var thisMac: String { t("This Mac", "本机") }
    var running: String { t("Running", "运行中") }
    var starting: String { t("Starting", "启动中") }
    var sessionColumn: String { t("Session", "会话 ID") }
    var agentColumn: String { "Agent" }
    var conversationColumn: String { t("Conversation", "对话 ID") }
    var statusColumn: String { t("Status", "状态") }
    var workingDirectoryColumn: String { t("Working Directory", "工作目录") }
    var pidColumn: String { "PID" }
    var updatedColumn: String { t("Updated", "更新时间") }
    var openErrorTitle: String { t("Session Could Not Be Opened", "无法打开会话") }
    var endConfirmationTitle: String { t("End this session?", "结束此会话？") }
    var endConfirmationAction: String { t("End Session", "结束会话") }
    var cancelAction: String { t("Cancel", "取消") }
    var okAction: String { t("OK", "好") }
    var endErrorTitle: String { t("Could Not End Session", "无法结束会话") }
    var enqueueCloseError: String { t("Could not queue the close request.", "无法将关闭请求加入队列。") }

    func emptyCatalog(_ hasEndpoints: Bool) -> String {
        hasEndpoints
            ? t("Select an endpoint to view its sessions.", "选择一个连接目标以查看会话。")
            : t("Start a local or SSH session to add its endpoint here.",
                "先启动本地或 SSH 会话，之后会在这里显示连接目标。")
    }

    var refreshHint: String { t("Select Refresh to query this endpoint.", "选择“刷新”查询此连接目标。") }
    var connecting: String { t("Connecting and loading sessions…", "正在连接并加载会话…") }
    var noSessions: String { t("No retained sessions were found on this endpoint.", "此连接目标没有可恢复的会话。") }
    var loadFailure: String { t("Could not load sessions.", "无法加载会话。") }

    func sessionCount(_ count: Int) -> String {
        t("\(count) retained session\(count == 1 ? "" : "s")", "\(count) 个会话")
    }

    func endReason(_ value: String) -> String {
        guard settings.isChinese else { return value.replacingOccurrences(of: "_", with: " ") }
        return switch value {
        case "process_exited": "进程已退出"
        case "explicit_close": "已关闭"
        case "detached_timeout": "保留期限已到"
        case "deadline": "已到期"
        case "agent_completed": "Agent 已完成"
        case "lost": "会话已丢失"
        default: value
        }
    }

    func localizedError(_ message: String) -> String {
        let prefixes: [(String, String)] = [
            ("Could not read the saved session endpoints:", "无法读取已保存的连接目标："),
            ("Could not save the session endpoint:", "无法保存连接目标："),
            ("The session runtime helper exited with code ", "会话运行时辅助进程退出，代码为 ")
        ]
        for (english, chinese) in prefixes where message.hasPrefix(english) {
            let suffix = String(message.dropFirst(english.count))
            return t(english, chinese) + suffix
        }
        switch message {
        case "Session query timed out.":
            return t("Session query timed out.", "查询会话超时。")
        case "The endpoint returned too much session data.":
            return t("The endpoint returned too much session data.", "连接目标返回的会话数据过多。")
        case "The endpoint returned invalid session data.":
            return t("The endpoint returned invalid session data.", "连接目标返回了无效的会话数据。")
        case "Could not load sessions.":
            return t("Could not load sessions.", "无法加载会话。")
        case "This session has already ended and cannot be attached.":
            return t("This session has already ended and cannot be attached.", "此会话已结束，无法重新附加。")
        case "Could not attach the existing session in a native terminal tab.":
            return t("Could not attach the existing session in a native terminal tab.",
                     "无法在原生终端标签中附加现有会话。")
        default:
            return settings.isChinese ? "详细信息：\(message)" : message
        }
    }

    func endpointName(_ endpoint: SessionRuntimeCatalogEndpoint) -> String {
        endpoint.descriptor.isLocal ? thisMac : endpoint.descriptor.displayEndpoint
    }
}

@MainActor
enum SessionRuntimeLibrary {
    private static var windowController: SessionRuntimeLibraryWindowController?

    static func show() {
        show(from: TerminalController.preferredParent?.window)
    }

    static func show(from parent: NSWindow?) {
        let controller = windowController ?? SessionRuntimeLibraryWindowController()
        windowController = controller
        controller.showWindow(nil)
        if let window = controller.window {
            window.title = SessionRuntimeLibraryStrings(language: OhMyGhosttySettings.shared.language).windowTitle
            if !window.isVisible {
                if let parent, parent.isVisible {
                    window.setFrameOrigin(NSPoint(
                        x: parent.frame.midX - window.frame.width / 2,
                        y: parent.frame.midY - window.frame.height / 2
                    ))
                } else {
                    window.center()
                }
            }
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.model.refreshIfSelected()
    }

    @discardableResult
    static func focusExisting(
        paneID: UUID,
        in controllers: [TerminalController]? = nil
    ) -> Bool {
        let candidates = controllersIncludingParked(controllers ?? TerminalController.all)
        guard let owner = candidates.first(where: { controller in
            controller.surfaceTree.contains(where: { $0.id == paneID })
        }), let surface = owner.surfaceTree.first(where: { $0.id == paneID }) else {
            return false
        }

        let coordinator = owner.workspaceCoordinator
        if owner.workspacePresentationIsParked {
            if let current = coordinator.liveControllers.first(where: {
                $0.windowSessionID == owner.windowSessionID && !$0.workspacePresentationIsParked
            }) {
                coordinator.requestWorkspaceSwitch(to: owner.workspaceID, from: current) { outcome in
                    guard outcome == .committed else { return }
                    _ = SessionRuntimeLibrary.focusExisting(paneID: paneID, in: [owner])
                }
                return true
            }
            owner.window?.makeKeyAndOrderFront(nil)
            coordinator.didActivate(owner)
            if owner.workspacePresentationIsParked {
                if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
                owner.focusedSurface = surface
                Ghostty.moveFocus(to: surface)
                return true
            }
        }
        if coordinator.hasNonNativeFullscreen(in: owner.windowSessionID) {
            _ = coordinator.selectNonNativeTab(owner)
        } else if let window = owner.window,
                  window.tabGroup?.selectedWindow !== window {
            if owner.tabLayout == .vertical {
                owner.selectVerticalTab(owner)
            } else {
                window.tabGroup?.selectedWindow = window
                owner.markTabActivated()
                window.makeKeyAndOrderFront(nil)
            }
        }
        owner.window?.makeKeyAndOrderFront(nil)
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        owner.focusedSurface = surface
        Ghostty.moveFocus(to: surface)
        return true
    }

    private static func controllersIncludingParked(_ controllers: [TerminalController]) -> [TerminalController] {
        var seen = Set<ObjectIdentifier>()
        let parked = Array(TerminalWorkspaceCoordinator.shared.parked.values) +
            controllers.flatMap { Array($0.workspaceCoordinator.parked.values) }
        return (controllers + Array(parked))
            .filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    @discardableResult
    static func openExisting(
        _ session: SessionRuntimeCatalogSession,
        descriptor: SessionRuntimeDescriptor,
        from parent: NSWindow? = nil,
        controllers: [TerminalController]? = nil
    ) throws -> TerminalController? {
        let parentWindow = parent ?? TerminalController.preferredParent?.window
        guard session.isAttachable, let paneID = session.paneID else {
            throw NSError(
                domain: "OMGSessionRuntime",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "This session has already ended and cannot be attached."]
            )
        }
        if focusExisting(paneID: paneID, in: controllers) { return nil }

        guard let delegate = NSApp.delegate as? AppDelegate,
              let nativeApp = delegate.ghostty.app else {
            throw CocoaError(.featureUnsupported)
        }
        var config = Ghostty.SurfaceConfiguration()
        try descriptor.configureAttachExisting(&config)
        config.workingDirectory = session.workingDirectory ?? descriptor.launchWorkingDirectory
        let surface = Ghostty.SurfaceView(nativeApp, baseConfig: config, uuid: paneID)
        let tree = SplitTree<Ghostty.SurfaceView>(view: surface)
        if let controller = TerminalController.newTab(
            delegate.ghostty,
            from: parentWindow,
            withSurfaceTree: tree
        ) {
            return controller
        }
        if parentWindow == nil {
            return TerminalController.newWindow(delegate.ghostty, tree: tree)
        }
        throw NSError(
            domain: "OMGSessionRuntime",
            code: 11,
            userInfo: [NSLocalizedDescriptionKey: "Could not attach the existing session in a native terminal tab."]
        )
    }
}

@MainActor
private final class SessionRuntimeLibraryWindowController: NSWindowController, NSWindowDelegate {
    let model = SessionRuntimeLibraryModel()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_040, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = SessionRuntimeLibraryStrings(language: OhMyGhosttySettings.shared.language).windowTitle
        window.minSize = NSSize(width: 780, height: 440)
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentViewController = SessionRuntimeLibraryViewController(model: model)
        window.isReleasedWhenClosed = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        model.cancelRefresh()
    }
}

@MainActor
private final class SessionRuntimeLibraryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let model: SessionRuntimeLibraryModel
    private let split = NSSplitView()
    private let endpointTable = NSTableView()
    private let sessionTable = NSTableView()
    private let endpointScroll = NSScrollView()
    private let sessionScroll = NSScrollView()
    private let endpointHeader = NSTextField(labelWithString: "ENDPOINTS")
    private let titleLabel = NSTextField(labelWithString: "Sessions")
    private let selectedEndpointLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let openButton = NSButton(title: "Open Existing", target: nil, action: nil)
    private let endButton = NSButton(title: "End Session…", target: nil, action: nil)
    private var observers: Set<AnyCancellable> = []
    private var selectingEndpoint = false
    private var strings: SessionRuntimeLibraryStrings {
        SessionRuntimeLibraryStrings(language: OhMyGhosttySettings.shared.language)
    }

    init(model: SessionRuntimeLibraryModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSVisualEffectView()
        root.material = .windowBackground
        root.blendingMode = .behindWindow
        root.state = .followsWindowActiveState
        view = root

        configureEndpointTable()
        configureSessionTable()
        configureControls()

        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(makeEndpointPane())
        split.addArrangedSubview(makeSessionPane())
        split.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        split.setPosition(230, ofDividerAt: 0)
        bindModel()
        refreshViews()
    }

    private func configureEndpointTable() {
        endpointHeader.stringValue = strings.endpointsHeader
        endpointTable.headerView = nil
        endpointTable.rowHeight = 42
        endpointTable.allowsEmptySelection = true
        endpointTable.allowsMultipleSelection = false
        endpointTable.dataSource = self
        endpointTable.delegate = self
        endpointTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("endpoint")))
    }

    private func configureSessionTable() {
        sessionTable.rowHeight = 30
        sessionTable.allowsEmptySelection = true
        sessionTable.allowsMultipleSelection = false
        sessionTable.doubleAction = #selector(openSelectedSession)
        sessionTable.target = self
        sessionTable.dataSource = self
        sessionTable.delegate = self
        for (identifier, title, width) in [
            ("session", strings.sessionColumn, CGFloat(110)),
            ("agent", strings.agentColumn, CGFloat(100)),
            ("conversation", strings.conversationColumn, CGFloat(190)),
            ("status", strings.statusColumn, CGFloat(130)),
            ("cwd", strings.workingDirectoryColumn, CGFloat(330)),
            ("pid", strings.pidColumn, CGFloat(70)),
            ("updated", strings.updatedColumn, CGFloat(140))
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            sessionTable.addTableColumn(column)
        }
        sessionTable.usesAlternatingRowBackgroundColors = true
    }

    private func configureControls() {
        titleLabel.stringValue = strings.sessionsTitle
        endpointHeader.font = .systemFont(ofSize: 11, weight: .bold)
        endpointHeader.textColor = .secondaryLabelColor
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        selectedEndpointLabel.font = .systemFont(ofSize: 12)
        selectedEndpointLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 2
        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(refreshOrCancel)
        openButton.bezelStyle = .rounded
        openButton.target = self
        openButton.action = #selector(openSelectedSession)
        endButton.bezelStyle = .rounded
        endButton.target = self
        endButton.action = #selector(endSelectedSession)
    }

    private func makeEndpointPane() -> NSView {
        let pane = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(stack)
        endpointScroll.documentView = endpointTable
        endpointScroll.hasVerticalScroller = true
        endpointScroll.drawsBackground = false
        endpointScroll.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(endpointHeader)
        stack.addArrangedSubview(endpointScroll)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: pane.topAnchor, constant: 15),
            stack.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -14),
            endpointScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            endpointScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
        return pane
    }

    private func makeSessionPane() -> NSView {
        let pane = NSView()
        let titleRow = NSStackView(views: [titleLabel, selectedEndpointLabel, NSView(), refreshButton])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 12
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        sessionScroll.documentView = sessionTable
        sessionScroll.hasVerticalScroller = true
        sessionScroll.hasHorizontalScroller = true
        sessionScroll.translatesAutoresizingMaskIntoConstraints = false

        let actionRow = NSStackView(views: [NSView(), endButton, openButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8
        actionRow.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(titleRow)
        pane.addSubview(statusLabel)
        pane.addSubview(errorLabel)
        pane.addSubview(sessionScroll)
        pane.addSubview(actionRow)
        NSLayoutConstraint.activate([
            titleRow.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 20),
            titleRow.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -20),
            titleRow.topAnchor.constraint(equalTo: pane.topAnchor, constant: 15),
            statusLabel.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: titleRow.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 10),
            errorLabel.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: titleRow.trailingAnchor),
            errorLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 3),
            sessionScroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 20),
            sessionScroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -20),
            sessionScroll.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 10),
            actionRow.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 20),
            actionRow.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -20),
            actionRow.topAnchor.constraint(equalTo: sessionScroll.bottomAnchor, constant: 12),
            actionRow.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -16)
        ])
        return pane
    }

    private func bindModel() {
        model.$endpoints.sink { [weak self] _ in self?.refreshViews() }.store(in: &observers)
        model.$sessions.sink { [weak self] _ in self?.refreshViews() }.store(in: &observers)
        model.$loadState.sink { [weak self] _ in self?.refreshViews() }.store(in: &observers)
        model.$selectedEndpointID.sink { [weak self] _ in self?.refreshViews() }.store(in: &observers)
        model.$selectedSessionID.sink { [weak self] _ in self?.refreshViews() }.store(in: &observers)
        model.$persistenceError.sink { [weak self] _ in self?.refreshViews() }.store(in: &observers)
        OhMyGhosttySettings.shared.$language.sink { [weak self] _ in self?.refreshViews() }.store(in: &observers)
    }

    private func refreshViews() {
        guard isViewLoaded else { return }
        endpointTable.reloadData()
        endpointHeader.stringValue = strings.endpointsHeader
        titleLabel.stringValue = strings.sessionsTitle
        for (identifier, title) in [
            ("session", strings.sessionColumn),
            ("agent", strings.agentColumn),
            ("conversation", strings.conversationColumn),
            ("status", strings.statusColumn),
            ("cwd", strings.workingDirectoryColumn),
            ("pid", strings.pidColumn),
            ("updated", strings.updatedColumn)
        ] {
            sessionTable.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(identifier))?.title = title
        }
        sessionTable.reloadData()
        selectingEndpoint = true
        if let id = model.selectedEndpointID,
           let row = model.endpoints.firstIndex(where: { $0.id == id }) {
            endpointTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            endpointTable.deselectAll(nil)
        }
        selectingEndpoint = false

        selectedEndpointLabel.stringValue = model.selectedEndpoint.map(strings.endpointName) ?? ""
        refreshButton.title = model.isLoading ? strings.cancel : strings.refresh
        openButton.title = strings.openExisting
        endButton.title = strings.endSession
        let selectedSession = model.sessions.first { $0.id == model.selectedSessionID }
        let canActOnSession: Bool
        if case .loaded = model.loadState { canActOnSession = true } else { canActOnSession = false }
        openButton.isEnabled = canActOnSession && selectedSession?.isAttachable == true
        endButton.isEnabled = canActOnSession && selectedSession?.ended == nil && selectedSession != nil

        switch model.loadState {
        case .idle:
            if model.selectedEndpoint == nil {
                statusLabel.stringValue = strings.emptyCatalog(model.endpoints.isEmpty)
            } else {
                statusLabel.stringValue = strings.refreshHint
            }
        case .loading:
            statusLabel.stringValue = strings.connecting
        case .loaded:
            statusLabel.stringValue = model.sessions.isEmpty
                ? strings.noSessions
                : strings.sessionCount(model.sessions.count)
        case .failed(let message):
            statusLabel.stringValue = strings.loadFailure
            errorLabel.stringValue = strings.localizedError(message)
        }
        if case .failed = model.loadState {} else {
            errorLabel.stringValue = model.persistenceError.map(strings.localizedError) ?? ""
        }
        view.window?.title = strings.windowTitle
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === endpointTable ? model.endpoints.count : model.sessions.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard let identifier = tableColumn?.identifier.rawValue else { return nil }
        if tableView === endpointTable {
            guard model.endpoints.indices.contains(row) else { return nil }
            let endpoint = model.endpoints[row]
            return strings.endpointName(endpoint)
        }
        guard model.sessions.indices.contains(row) else { return nil }
        let session = model.sessions[row]
        switch identifier {
        case "session": return session.id.prefix(8).description
        case "agent": return session.agentLabel ?? "—"
        case "conversation": return session.resume?.conversationID ?? "—"
        case "status": return session.statusLabel(using: strings)
        case "cwd": return session.workingDirectory ?? "—"
        case "pid": return session.pid.map(String.init) ?? "—"
        case "updated": return Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(session.updatedAt)))
        default: return nil
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === endpointTable, !selectingEndpoint {
            let row = endpointTable.selectedRow
            model.selectedEndpointID = model.endpoints.indices.contains(row) ? model.endpoints[row].id : nil
        } else if table === sessionTable {
            let row = sessionTable.selectedRow
            model.selectSession(model.sessions.indices.contains(row) ? model.sessions[row] : nil)
        }
    }

    @objc private func refreshOrCancel() {
        if model.isLoading { model.cancelRefresh() } else { model.refresh() }
    }

    @objc private func openSelectedSession() {
        guard let endpoint = model.selectedEndpoint,
              let session = model.sessions.first(where: { $0.id == model.selectedSessionID }) else { return }
        do {
            _ = try SessionRuntimeLibrary.openExisting(
                session,
                descriptor: endpoint.descriptor,
                from: TerminalController.preferredParent?.window
            )
        } catch {
            showError(strings.openErrorTitle, message: strings.localizedError(error.localizedDescription))
        }
    }

    @objc private func endSelectedSession() {
        guard let endpoint = model.selectedEndpoint,
              let session = model.sessions.first(where: { $0.id == model.selectedSessionID }),
              session.ended == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = strings.endConfirmationTitle
        let endpointName = strings.endpointName(endpoint)
        alert.informativeText = strings.t(
            "This ends session \(session.id) on \(endpointName). If the endpoint is disconnected, the request will wait until it reconnects.",
            "这会结束 \(endpointName) 上的会话 \(session.id)。如果连接断开，请求会在连接恢复后发送。"
        )
        alert.addButton(withTitle: strings.endConfirmationAction)
        alert.addButton(withTitle: strings.cancelAction)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try model.end(session)
        } catch {
            showError(strings.endErrorTitle, message: "\(strings.enqueueCloseError) \(error.localizedDescription)")
        }
    }

    private func showError(_ title: String, message: String) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: strings.okAction)
        alert.beginSheetModal(for: window)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}
