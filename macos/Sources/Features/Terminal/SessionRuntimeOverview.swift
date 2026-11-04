import AppKit
import Combine

struct SessionRuntimeOverviewEntry: Decodable, Identifiable {
    let endpointID: String
    let host: String
    let revision: String
    let session: SessionRuntimeCatalogSession
    var id: String { endpointID + ":" + session.id }
    enum CodingKeys: String, CodingKey { case host, revision; case endpointID = "endpoint_id" }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        endpointID = try values.decode(String.self, forKey: .endpointID)
        host = try values.decode(String.self, forKey: .host)
        revision = try values.decode(String.self, forKey: .revision)
        session = try SessionRuntimeCatalogSession(from: decoder)
    }
}

struct SessionRuntimeOverviewReport: Decodable {
    struct Failure: Decodable { let host: String; let message: String }
    var sessions: [SessionRuntimeOverviewEntry]
    var errors: [Failure]
    var closed: Int
}

@MainActor
final class SessionRuntimeOverviewModel: ObservableObject {
    typealias Operation = @MainActor (Bool) async throws -> SessionRuntimeOverviewReport
    @Published private(set) var report = SessionRuntimeOverviewReport(sessions: [], errors: [], closed: 0)
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private var generation = 0
    private let operation: Operation
    var runningCount: Int { report.sessions.filter { $0.session.ended == nil }.count }
    var canCloseAll: Bool { !busy && error == nil && report.errors.isEmpty && runningCount > 0 }
    init(operation: Operation? = nil) { self.operation = operation ?? Self.runCLI }
    func refresh() { run(close: false) }
    func closeAll() { guard canCloseAll else { return }; run(close: true) }
    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        busy = false
    }
    private func run(close: Bool) {
        cancel()
        let request = generation
        busy = true
        error = nil
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if request == generation { busy = false; task = nil } }
            do {
                let result = try await operation(close)
                guard !Task.isCancelled, request == generation else { return }
                report = result
                if close, result.errors.isEmpty {
                    let refreshed = try await operation(false)
                    guard !Task.isCancelled, request == generation else { return }
                    report = refreshed
                    report.closed = result.closed
                }
            } catch {
                if request == generation, !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
    private static func runCLI(close: Bool) async throws -> SessionRuntimeOverviewReport {
        var arguments = ["sessions", close ? "close" : "list"]
        if close { arguments += ["--all", "--yes"] }
        arguments += ["--json", "--app-support", OMGApplicationEnvironment.applicationSupportURL().path]
        let result = try await GitProcessRunner().run(
            executablePath: SessionRuntimeConnections.resources.appendingPathComponent("omgd").path,
            arguments: arguments, workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            maxOutputBytes: 8 * 1024 * 1024, timeout: 180)
        // Exit 1 may contain a useful partial inventory and per-host errors.
        if let report = try? JSONDecoder().decode(SessionRuntimeOverviewReport.self, from: result.stdout) { return report }
        throw GitExecutionError.processFailed(exitCode: result.exitCode, stderr: result.stderrString)
    }
}

@MainActor
enum SessionRuntimeOverview {
    private static var windowController: OverviewWindow?
    static func show() {
        let controller = windowController ?? OverviewWindow()
        windowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.model.refresh()
    }
}

@MainActor
private final class OverviewWindow: NSWindowController, NSWindowDelegate {
    let model = SessionRuntimeOverviewModel()
    init() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = SettingsStrings(language: OhMyGhosttySettings.shared.language).t("All Background Sessions", "所有后台会话")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = OverviewController(model: model)
        window.setContentSize(.init(width: 980, height: 540))
        window.minSize = .init(width: 760, height: 400)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowWillClose(_ notification: Notification) { model.cancel() }
}

@MainActor
private final class OverviewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let model: SessionRuntimeOverviewModel
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let refresh = SettingsActionButton("") {}
    private let close = SettingsActionButton("") {}
    private let open = SettingsActionButton("") {}
    private var token: AnyCancellable?
    private var strings: SettingsStrings { .init(language: OhMyGhosttySettings.shared.language) }
    init(model: SessionRuntimeOverviewModel) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = NativeSettingsCanvas()
        for (id, title, width) in [
            ("host", strings.t("Host", "主机"), 150.0), ("id", strings.t("Session", "会话"), 100.0),
            ("state", strings.t("State", "状态"), 110.0), ("agent", "Agent", 90.0),
            ("pid", "PID", 70.0), ("cwd", strings.t("Directory", "目录"), 300.0)
        ] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 30
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        status.font = .systemFont(ofSize: 12)
        status.maximumNumberOfLines = 3
        refresh.title = strings.t("Refresh", "刷新")
        refresh.invoke = { [weak model] in model?.refresh() }
        close.title = strings.t("Close all sessions…", "关闭全部会话…")
        close.invoke = { [weak self] in self?.confirmClose() }
        open.title = strings.t("Open session", "打开会话")
        open.invoke = { [weak self] in self?.openSelected() }
        let footer = NSStackView(views: [status, NSView(), refresh, close, open])
        for child in [scroll, footer] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            scroll.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            footer.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18)
        ])
        token = model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.update() }
        update()
    }
    private func update() {
        table.reloadData()
        close.isEnabled = model.canCloseAll
        refresh.isEnabled = !model.busy
        open.isEnabled = !model.busy && model.report.sessions.indices.contains(table.selectedRow)
        let failures = model.report.errors.map { "\($0.host): \($0.message)" }
        status.stringValue = model.busy ? strings.t("Loading…", "正在查询…") :
            model.error ?? (!failures.isEmpty ? strings.t("Some hosts are unavailable. No bulk close is available.", "部分主机无法查询，暂不能全部关闭。") :
                strings.t("\(model.runningCount) running sessions", "\(model.runningCount) 个运行中的会话"))
        status.toolTip = ([model.error].compactMap { $0 } + failures).joined(separator: "\n")
    }
    func numberOfRows(in tableView: NSTableView) -> Int { model.report.sessions.count }
    func tableView(_ tableView: NSTableView, objectValueFor column: NSTableColumn?, row: Int) -> Any? {
        guard model.report.sessions.indices.contains(row) else { return nil }
        let entry = model.report.sessions[row], session = entry.session
        switch column?.identifier.rawValue {
        case "host": return entry.host == "This Mac" ? strings.t("This Mac", "本机") : entry.host
        case "id": return String(session.id.prefix(8))
        case "state": return session.statusLabel(using: .init(language: OhMyGhosttySettings.shared.language))
        case "agent": return session.agentLabel ?? "—"
        case "pid": return session.pid.map(String.init) ?? "—"
        case "cwd": return session.workingDirectory ?? "—"
        default: return nil
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        open.isEnabled = !model.busy && model.report.sessions.indices.contains(table.selectedRow) &&
            model.report.sessions[table.selectedRow].session.isAttachable
    }
    private func openSelected() {
        guard model.report.sessions.indices.contains(table.selectedRow) else { return }
        let entry = model.report.sessions[table.selectedRow]
        guard let endpoint = SessionRuntimeCatalog.shared.endpoints.first(where: { $0.id == entry.endpointID }) else { return }
        do { _ = try SessionRuntimeLibrary.openExisting(entry.session, descriptor: endpoint.descriptor) } catch {
            if let window = view.window { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }
    private func confirmClose() {
        guard model.canCloseAll, let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = strings.t("Close all background sessions?", "关闭全部后台会话？")
        alert.informativeText = strings.t(
            "This ends programs in all local and saved SSH sessions for this app. It cannot be undone.",
            "将结束此应用的所有本地和已保存 SSH 会话中运行的程序。此操作无法撤销。")
        alert.addButton(withTitle: strings.t("Close all", "全部关闭"))
        alert.addButton(withTitle: strings.t("Cancel", "取消"))
        alert.beginSheetModal(for: window) { [weak model] result in
            if result == .alertFirstButtonReturn { model?.closeAll() }
        }
    }
}
