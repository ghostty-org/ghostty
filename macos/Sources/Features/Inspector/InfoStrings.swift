import Foundation

struct InfoStrings: Equatable, Sendable {
    private let settings: SettingsStrings

    init(
        language: OhMyGhosttyLanguage = .system,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        self.settings = SettingsStrings(
            language: language,
            preferredLanguages: preferredLanguages
        )
    }

    @MainActor static var current: Self {
        .init(language: OhMyGhosttySettings.shared.language)
    }

    private func t(_ english: String, _ chinese: String) -> String {
        settings.isChinese ? chinese : english
    }

    var infoTitle: String { t("Info", "信息") }
    var portsTitle: String { t("Ports", "端口") }
    var remoteTargetColumn: String { t("Remote Target", "远端目标") }
    var forwardedAddressColumn: String { t("Forwarded Address", "转发地址") }
    var forwardAPort: String { t("Forward a Port", "转发端口") }
    var noForwardedPorts: String { t("No Forwarded Ports", "暂无转发端口") }
    var noForwardedPortsMessage: String {
        t(
            "Add a remote port or host:port to make it available on this Mac.",
            "添加远端端口或 host:port，使其可在这台 Mac 上访问。"
        )
    }
    var targetPlaceholder: String { t("Port or host:port", "端口或 host:port") }
    var cancel: String { t("Cancel", "取消") }
    var forward: String { t("Forward", "转发") }
    var openInBrowser: String { t("Open in Browser", "在浏览器中打开") }
    var copyForwardedAddress: String { t("Copy Forwarded Address", "复制转发地址") }
    var stopForwarding: String { t("Stop Forwarding", "停止转发") }
    var startingForward: String { t("Starting port forwarding…", "正在启动端口转发…") }

    func remotePortAccessibility(_ port: Int, detail: String) -> String {
        t(
            "Remote port \(port), \(detail)",
            "远端端口 \(port)，\(detail)"
        )
    }

    func targetHelp(alias: String) -> String {
        t(
            "Enter a port on \(alias), or a host:port reachable from it. The same local port is preferred when available.",
            "输入 \(alias) 上的端口，或它可访问的 host:port。本地端口可用时优先保持相同端口。"
        )
    }

    func connectPrompt() -> String {
        t(
            "Connect this Pane to an SSH host to inspect remote information.",
            "请在当前窗格连接 SSH 主机以查看远端信息。"
        )
    }

    func waitingForHost(_ alias: String) -> String {
        t(
            "Waiting for \(alias) to become ready…",
            "正在等待 \(alias) 连接就绪…"
        )
    }

    func listenerTimeout(localPort: Int) -> String {
        t(
            "Timed out waiting for localhost:\(localPort) to start listening.",
            "等待 localhost:\(localPort) 开始监听时超时。"
        )
    }

    func localPortInUse(_ localPort: Int) -> String {
        t(
            "Local port \(localPort) is already in use.",
            "本地端口 \(localPort) 已被占用。"
        )
    }

    var authenticationFailed: String {
        t("SSH authentication failed: permission denied.", "SSH 认证失败：权限被拒绝。")
    }
    var hostKeyFailed: String {
        t("SSH host key verification failed.", "SSH 主机密钥验证失败。")
    }
    var resolveHostFailed: String {
        t("SSH could not resolve the configured host.", "SSH 无法解析配置的主机。")
    }
    var connectionRefused: String {
        t("SSH connection was refused.", "SSH 连接被拒绝。")
    }
    var connectionTimedOut: String {
        t("SSH connection timed out.", "SSH 连接超时。")
    }

    func allocatePortFailed(_ detail: String) -> String {
        t(
            "Unable to allocate a local port: \(detail)",
            "无法分配本地端口：\(detail)"
        )
    }

    func sshExited(status: Int32) -> String {
        t(
            "SSH port forwarding exited with status \(status).",
            "SSH 端口转发已退出，状态码为 \(status)。"
        )
    }

    var historyTitle: String { t("Command History", "历史命令") }
    var agentPromptsTitle: String { t("Agent Prompts", "提问历史") }
    var noHistory: String { t("No History Recorded", "暂无历史命令") }
    var noHistoryMessage: String {
        t("Commands executed in this pane will appear here.", "在当前窗格执行的命令将显示在此处。")
    }
    var noAgentPrompts: String { t("No Prompts Recorded", "暂无提问记录") }
    var noAgentPromptsMessage: String {
        t("Prompts sent to this agent will appear here.", "发送给该 Agent 的 Prompt 将显示在此处。")
    }
    var clickToJump: String {
        t("Jump to this input in the terminal", "跳转到这次输入的位置")
    }
    var historyRowHelp: String {
        t("Select to copy with ⌘C. Double-click to jump.", "单击选中后按 ⌘C 复制，双击跳转。")
    }
    var noTerminalAnchor: String {
        t("Copy available. This transcript has no verified terminal positions.", "可复制；此会话尚无可靠的终端位置映射。")
    }
    var archivedCommandLabel: String { t("saved · read-only", "已保存 · 仅查看") }
    var archivedCommandHelp: String {
        t("Saved command; its terminal anchor is no longer available. Select and copy with ⌘C.",
          "已保存的命令，终端锚点已不可用。单击选中后按 ⌘C 复制。")
    }
    var unknownHistoryDate: String { t("Date unavailable", "日期未知") }
    var historyLoading: String { t("Loading prompts…", "正在读取提问…") }
    var historyUnavailable: String {
        t("Session history unavailable. Retrying automatically…", "暂时无法读取会话记录，正在自动重试…")
    }
    var historyLimited: String {
        t("Showing recent prompts. Older or oversized records may be omitted.", "仅显示近期提问，较早或超大记录可能未收录。")
    }
}
