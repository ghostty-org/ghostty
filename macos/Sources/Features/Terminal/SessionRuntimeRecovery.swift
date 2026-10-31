import AppKit
import SwiftUI

extension TerminalController {
    /// Ask the host-scoped relay to retry transport and reattach this same UUID.
    func retryRuntimeConnection(
        for surface: Ghostty.SurfaceView,
        using retryer: SessionRuntimeRetrying = SessionRuntimeConnections.shared
    ) {
        guard surface.surface != nil, let descriptor = surface.runtimeDescriptor,
              surfaceTree.contains(where: { $0 === surface }),
              surface.runtimeConnectionState?.canRetry != false else { return }
        let attempt = (surface.runtimeConnectionState?.attempt ?? 0) + 1
        let requestedState = SessionRuntimeConnectionState.reconnecting(
            attempt: attempt,
            retryInMilliseconds: nil
        )
        surface.runtimeConnectionState = requestedState
        do {
            try retryer.retry(descriptor) { [weak surface] message in
                guard let surface,
                      surface.runtimeDescriptor == descriptor,
                      surface.runtimeConnectionState == requestedState else { return }
                surface.runtimeConnectionState = .failed(message: message)
            }
        } catch {
            surface.runtimeConnectionState = .failed(message: error.localizedDescription)
        }
    }
}

struct SessionRuntimeRecoveryBanner: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var settings = OhMyGhosttySettings.shared
    @ObservedObject var surface: Ghostty.SurfaceView

    var body: some View {
        if surface.surface != nil, let descriptor = surface.runtimeDescriptor,
           let state = surface.runtimeConnectionState,
           state != .ready {
            NativeSessionRuntimeRecoveryBanner(
                endpoint: descriptor.displayEndpoint,
                state: state,
                strings: SettingsStrings(language: settings.language)
            ) { [weak controller, weak surface] in
                guard let controller, let surface,
                      surface.runtimeDescriptor == descriptor,
                      controller.surfaceTree.contains(where: { $0 === surface }) else { return }
                controller.retryRuntimeConnection(for: surface)
            }
        }
    }
}

private struct NativeSessionRuntimeRecoveryBanner: NSViewRepresentable {
    let endpoint: String
    let state: SessionRuntimeConnectionState
    let strings: SettingsStrings
    let retry: () -> Void

    func makeNSView(context: Context) -> SessionRuntimeRecoveryView {
        SessionRuntimeRecoveryView()
    }

    func updateNSView(_ view: SessionRuntimeRecoveryView, context: Context) {
        view.update(endpoint: endpoint, state: state, strings: strings, retry: retry)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SessionRuntimeRecoveryView,
                      context: Context) -> CGSize? {
        let width = proposal.width ?? 480
        return CGSize(width: width, height: nsView.height(for: width))
    }
}

/// Native status and retry controls stay attached to the session's pane.
final class SessionRuntimeRecoveryView: NSVisualEffectView {
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(wrappingLabelWithString: "")
    let reconnectButton = NSButton(title: "", target: nil, action: nil)
    private let icon = NSImageView()
    private let separator = NSBox()
    private var retry: (() -> Void)?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        material = .headerView
        blendingMode = .withinWindow
        state = .followsWindowActiveState
        setAccessibilityIdentifier("sessionRuntimeRecoveryBanner")
        titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 0
        icon.contentTintColor = .secondaryLabelColor
        reconnectButton.bezelStyle = .rounded
        reconnectButton.controlSize = .small
        reconnectButton.target = self
        reconnectButton.action = #selector(performRetry)
        reconnectButton.setAccessibilityIdentifier("sessionRuntimeReconnect")
        // No Return key equivalent: this passive banner must not intercept terminal input.
        separator.boxType = .separator
        for child in [icon, titleLabel, detailLabel, reconnectButton, separator] {
            addSubview(child)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(endpoint: String, state: SessionRuntimeConnectionState,
                strings: SettingsStrings, retry: @escaping () -> Void) {
        titleLabel.stringValue = strings.runtimeStatusTitle(state) + " · " + endpoint
        titleLabel.toolTip = endpoint
        detailLabel.stringValue = strings.runtimeStatusDetail(state)
        reconnectButton.title = strings.runtimeRetryNow
        reconnectButton.toolTip = strings.runtimeRetryHelp
        reconnectButton.isHidden = !state.canRetry
        icon.image = NSImage(
            systemSymbolName: state.isInProgress ? "arrow.triangle.2.circlepath" : "network.slash",
            accessibilityDescription: nil
        )
        self.retry = retry
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func height(for width: CGFloat) -> CGFloat {
        20 + titleLabel.intrinsicContentSize.height + 6 + detailHeight(for: width) +
            (reconnectButton.isHidden ? 1 : 6 + reconnectButton.intrinsicContentSize.height + 1)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(for: bounds.width))
    }

    override func layout() {
        super.layout()
        let width = max(0, bounds.width - 46)
        icon.frame = NSRect(x: 10, y: 10, width: 16, height: 16)
        let titleHeight = titleLabel.intrinsicContentSize.height
        titleLabel.frame = NSRect(x: 36, y: 10, width: width, height: titleHeight)
        let textHeight = detailHeight(for: bounds.width)
        detailLabel.frame = NSRect(x: 36, y: titleLabel.frame.maxY + 6, width: width, height: textHeight)
        let buttonSize = reconnectButton.intrinsicContentSize
        reconnectButton.frame = NSRect(
            x: 36,
            y: detailLabel.frame.maxY + 6,
            width: min(width, buttonSize.width),
            height: buttonSize.height
        )
        separator.frame = NSRect(x: 0, y: max(0, bounds.height - 1), width: bounds.width, height: 1)
    }

    private func detailHeight(for width: CGFloat) -> CGFloat {
        let textWidth = max(1, width - 46)
        return ceil((detailLabel.stringValue as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: detailLabel.font ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
        ).height)
    }

    @objc private func performRetry() {
        retry?()
    }
}

private extension SessionRuntimeConnectionState {
    var isInProgress: Bool {
        switch self {
        case .connecting, .reconnecting: true
        case .attention, .ready, .failed, .exited: false
        }
    }
}

private extension SettingsStrings {
    func runtimeStatusTitle(_ state: SessionRuntimeConnectionState) -> String {
        switch state {
        case .connecting: t("Connecting", "正在连接")
        case .reconnecting: t("Reconnecting", "正在重连")
        case .attention: t("Connection needs attention", "连接需要处理")
        case .ready: t("Connected", "已连接")
        case .failed: t("Session connection failed", "会话连接失败")
        case .exited: t("Session ended", "会话已结束")
        }
    }

    func runtimeStatusDetail(_ state: SessionRuntimeConnectionState) -> String {
        switch state {
        case .connecting:
            return t("Starting the session runtime.", "正在启动会话运行时。")
        case .reconnecting(let attempt, let retryInMilliseconds):
            let attemptText = t("Attempt \(attempt)", "第 \(attempt) 次尝试")
            guard let retryInMilliseconds else { return attemptText }
            let seconds = max(1, (retryInMilliseconds + 999) / 1_000)
            return attemptText + " · " + t("retry in \(seconds)s", "\(seconds) 秒后重试")
        case .attention(let attempt, let message):
            let fallback = t("Automatic retries stopped. Retry when the host is reachable.", "自动重试已暂停；主机恢复后可手动重试。")
            let reason = message?.isEmpty == false ? message! : fallback
            return attempt > 0 ? t("Attempt \(attempt) · \(reason)", "第 \(attempt) 次尝试 · \(reason)") : reason
        case .ready:
            return t("The original session is attached.", "已连接到原会话。")
        case .failed(let message, _):
            return message?.isEmpty == false ? message! : t("The session could not be attached.", "无法连接到原会话。")
        case .exited(let exitCode):
            return t("The session process exited with code \(exitCode).", "会话进程以退出码 \(exitCode) 结束。")
        }
    }
}
