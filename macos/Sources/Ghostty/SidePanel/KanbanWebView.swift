import SwiftUI
import WebKit

struct KanbanWebView: NSViewRepresentable {
    @ObservedObject var boardState: BoardState
    var viewModel: SidePanelViewModel?
    @Binding var showTaskModal: Bool
    var containerWidth: CGFloat
    var isNarrow: Bool

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptEnabled = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        webView.configuration.userContentController.add(context.coordinator, name: "kanbanBridge")

        context.coordinator.webView = webView
        context.coordinator.boardState = boardState
        context.coordinator.viewModel = viewModel
        context.coordinator.isNarrow = isNarrow
        context.coordinator.containerWidth = containerWidth

        if let html = context.coordinator.loadHTML() {
            webView.loadHTMLString(html, baseURL: Bundle.main.bundleURL)
        } else {
            webView.loadHTMLString("<html><body><h1>Error loading board.html</h1></body></html>", baseURL: nil)
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.boardState = boardState
        context.coordinator.viewModel = viewModel
        context.coordinator.isNarrow = isNarrow
        context.coordinator.containerWidth = containerWidth
        context.coordinator.updateLayout()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var boardState: BoardState?
        weak var viewModel: SidePanelViewModel?
        var isNarrow: Bool = false
        var containerWidth: CGFloat = 0
        let parent: KanbanWebView

        init(_ parent: KanbanWebView) {
            self.parent = parent
        }

        private func createAndAttachSession(
            taskUUID: UUID,
            cwd: String,
            isWorkTree: Bool,
            worktreeName: String?,
            boardState: BoardState
        ) {
            let session: Session

            if let viewModel = self.viewModel {
                session = viewModel.createSessionAndOpenSplit(
                    cwd: cwd,
                    isWorkTree: isWorkTree,
                    worktreeName: worktreeName
                )
            } else {
                session = SessionManager.shared.createSession(
                    cwd: cwd,
                    isWorktree: isWorkTree,
                    worktreeName: worktreeName
                )
            }

            boardState.addSession(to: taskUUID, session: session)
        }

        // MARK: - Layout Update

        func updateLayout() {
            guard let webView = webView else { return }

            let script = "updateLayout(\(containerWidth), \(isNarrow ? "true" : "false"));"
            webView.evaluateJavaScript(script) { _, error in
                if let error = error {
                    print("[KanbanWebView] Layout update error: \(error)")
                }
            }
        }

        // MARK: - HTML Loading

        func loadHTML() -> String? {
            guard let url = Bundle.main.url(forResource: "board", withExtension: "html", subdirectory: "Kanban"),
                  let html = try? String(contentsOf: url, encoding: .utf8) else {
                print("[KanbanWebView] Failed to load board.html from bundle")
                return nil
            }
            return html
        }

        // MARK: - WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self = self, let boardState = self.boardState else { return }

                switch type {
                case "themeToggle":
                    if let isDark = body["isDark"] as? Bool {
                        boardState.isDarkMode = isDark
                    }

                case "addTask":
                    if let taskData = body["task"] as? [String: Any] {
                        let task = KanbanTask(
                            title: taskData["title"] as? String ?? "",
                            description: taskData["description"] as? String ?? "",
                            priority: Priority(rawValue: taskData["priority"] as? String ?? "p2") ?? .p2,
                            status: .todo
                        )
                        boardState.addTask(task)
                        self.sendBoardState()
                    }

                case "updateTask":
                    if let taskId = body["taskId"] as? String,
                       let taskData = body["task"] as? [String: Any],
                       let uuid = UUID(uuidString: taskId),
                       let existing = boardState.tasks.first(where: { $0.id == uuid }) {
                        var updated = existing
                        updated.title = taskData["title"] as? String ?? existing.title
                        updated.description = taskData["description"] as? String ?? existing.description
                        if let p = taskData["priority"] as? String {
                            updated.priority = Priority(rawValue: p) ?? existing.priority
                        }
                        boardState.updateTask(updated)
                        self.sendBoardState()
                    }

                case "moveTask":
                    if let taskId = body["taskId"] as? String,
                       let newStatus = body["newStatus"] as? String,
                       let uuid = UUID(uuidString: taskId),
                       let status = Status(rawValue: newStatus) {
                        boardState.moveTask(uuid, to: status)
                        self.sendBoardState()
                    }

                case "toggleExpand":
                    if let taskId = body["taskId"] as? String,
                       let uuid = UUID(uuidString: taskId) {
                        boardState.toggleTaskExpanded(uuid)
                        self.sendBoardState()
                    }

                case "deleteTask":
                    if let taskId = body["taskId"] as? String,
                       let uuid = UUID(uuidString: taskId) {
                        boardState.deleteTask(uuid)
                        self.sendBoardState()
                    }

                case "removeSession":
                    if let taskId = body["taskId"] as? String,
                       let sessionId = body["sessionId"] as? String,
                       let taskUUID = UUID(uuidString: taskId),
                       let sessionUUID = UUID(uuidString: sessionId) {
                        boardState.removeSession(from: taskUUID, sessionId: sessionUUID)
                        self.sendBoardState()
                    }

                case "addSession":
                    if let taskId = body["taskId"] as? String,
                       let taskUUID = UUID(uuidString: taskId) {
                        createAndAttachSession(
                            taskUUID: taskUUID,
                            cwd: FileManager.default.homeDirectoryForCurrentUser.path,
                            isWorkTree: false,
                            worktreeName: nil,
                            boardState: boardState
                        )
                        self.sendBoardState()
                    }

                case "openSession":
                    if let sessionId = body["sessionId"] as? String,
                       let uuid = UUID(uuidString: sessionId) {
                        SessionManager.shared.navigateToSession(id: uuid)
                    }

                case "createSessionAndLink":
                    if let taskId = body["taskId"] as? String,
                       let cwd = body["cwd"] as? String,
                       let isWorkTree = body["isWorkTree"] as? Bool,
                       let taskUUID = UUID(uuidString: taskId) {
                        let worktreeName = body["worktreeName"] as? String

                        createAndAttachSession(
                            taskUUID: taskUUID,
                            cwd: cwd,
                            isWorkTree: isWorkTree,
                            worktreeName: worktreeName,
                            boardState: boardState
                        )
                        self.sendBoardState()
                    }

                case "unlinkSession":
                    if let sessionId = body["sessionId"] as? String,
                       let uuid = UUID(uuidString: sessionId) {
                        SessionManager.shared.unlinkSession(id: uuid)
                        self.sendBoardState()
                    }

                case "refreshSessions":
                    SessionManager.shared.loadSessions()
                    self.sendBoardState()

                default:
                    break
                }
            }
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            sendBoardState()
        }

        // MARK: - Send State to WebView

        func sendBoardState() {
            guard let webView = webView,
                  let boardState = boardState else { return }

            boardState.refreshSessionsFromManager()

            let tasks = boardState.tasks.map { task -> [String: Any] in
                return [
                    "id": task.id.uuidString,
                    "title": task.title,
                    "description": task.description,
                    "priority": task.priority.rawValue,
                    "status": task.status.rawValue,
                    "isExpanded": task.isExpanded,
                    "sessions": task.sessions.map { session -> [String: Any] in
                        return [
                            "id": session.id.uuidString,
                            "title": session.title,
                            "status": session.status.rawValue,
                            "relativeTimestamp": session.relativeTimestamp,
                            "isWorkTree": session.isWorkTree,
                            "branch": session.branch
                        ]
                    }
                ]
            }

            let script = """
            (function() {
                updateBoardState({ tasks: \(encodeToJSON(tasks)) });
                setDarkMode(\(boardState.isDarkMode ? "true" : "false"));
            })();
            """

            webView.evaluateJavaScript(script) { _, error in
                if let error = error {
                    print("[KanbanWebView] JS error: \(error)")
                }
            }
        }

        private func encodeToJSON(_ value: Any) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: []),
                  let string = String(data: data, encoding: .utf8) else {
                return "[]"
            }
            return string
        }
    }
}
