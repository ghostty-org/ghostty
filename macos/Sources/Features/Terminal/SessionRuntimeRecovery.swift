import AppKit
import SwiftUI

extension TerminalController {
    /// Recreate only the SSH relay and attach the same remote Session ID.
    /// A fresh local PTY is never used as a tmux/attach wrapper.
    func reconnectRuntimeHere(for surface: Ghostty.SurfaceView) {
        guard let descriptor = surface.runtimeDescriptor,
              let app = ghostty.app,
              let node = surfaceTree.find(id: surface.id) else { return }
        SessionRuntimeConnections.shared.invalidate(descriptor)
        var config = Ghostty.SurfaceConfiguration()
        do { try descriptor.configure(&config) } catch { return }
        let replacement = Ghostty.SurfaceView(app, baseConfig: config, uuid: surface.id)
        replacement.runtimeLocalSurface = surface.runtimeLocalSurface
        replacement.runtimeLocalCompletion = surface.runtimeLocalCompletion
        guard let tree = try? surfaceTree.replacing(node: node, with: .leaf(view: replacement)) else { return }
        replaceSurfaceTree(tree, moveFocusTo: replacement, moveFocusFrom: surface, undoAction: nil)
        focusedSurface = replacement
        invalidateRestorableState()
    }
}

struct SessionRuntimeRecoveryBanner: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var settings = OhMyGhosttySettings.shared
    @ObservedObject var surface: Ghostty.SurfaceView

    var body: some View {
        if surface.runtimeDisconnected, let descriptor = surface.runtimeDescriptor {
            NativeSessionRuntimeRecoveryBanner(
                endpoint: descriptor.connection.displayEndpoint,
                strings: SettingsStrings(language: settings.language)
            ) { [weak controller, weak surface] in
                guard let controller, let surface,
                      surface.runtimeDisconnected,
                      surface.runtimeDescriptor == descriptor,
                      controller.surfaceTree.contains(where: { $0 === surface }) else { return }
                controller.reconnectRuntimeHere(for: surface)
            }
        }
    }
}

private struct NativeSessionRuntimeRecoveryBanner: NSViewRepresentable {
    let endpoint: String
    let strings: SettingsStrings
    let reconnect: () -> Void

    func makeNSView(context: Context) -> SessionRuntimeRecoveryView {
        SessionRuntimeRecoveryView()
    }

    func updateNSView(_ view: SessionRuntimeRecoveryView, context: Context) {
        view.update(endpoint: endpoint, strings: strings, reconnect: reconnect)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SessionRuntimeRecoveryView,
                      context: Context) -> CGSize? {
        let width = proposal.width ?? 480
        return CGSize(width: width, height: nsView.height(for: width))
    }
}

/// Native controls stay attached to their pane; the adapter only supplies recovery state.
final class SessionRuntimeRecoveryView: NSVisualEffectView {
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(wrappingLabelWithString: "")
    let reconnectButton = NSButton(title: "", target: nil, action: nil)
    private let icon = NSImageView()
    private let separator = NSBox()
    private var reconnect: (() -> Void)?

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
        icon.image = NSImage(systemSymbolName: "network.slash", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        reconnectButton.bezelStyle = .rounded
        reconnectButton.controlSize = .small
        reconnectButton.target = self
        reconnectButton.action = #selector(performReconnect)
        reconnectButton.setAccessibilityIdentifier("sessionRuntimeReconnect")
        // No Return key equivalent: a passive banner must not intercept terminal input.
        separator.boxType = .separator
        for child in [icon, titleLabel, detailLabel, reconnectButton, separator] {
            addSubview(child)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(endpoint: String, strings: SettingsStrings, reconnect: @escaping () -> Void) {
        titleLabel.stringValue = strings.sshRecoveryTitle + " · " + endpoint
        titleLabel.toolTip = endpoint
        detailLabel.stringValue = strings.runtimeRecoveryHelp
        reconnectButton.title = strings.runtimeRecoveryReconnect
        reconnectButton.toolTip = strings.runtimeRecoveryHelp
        self.reconnect = reconnect
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func height(for width: CGFloat) -> CGFloat {
        20 + titleLabel.intrinsicContentSize.height + 6 + detailHeight(for: width) +
            6 + reconnectButton.intrinsicContentSize.height + 1
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
        reconnectButton.frame = NSRect(x: 36, y: detailLabel.frame.maxY + 6,
                                      width: min(width, buttonSize.width), height: buttonSize.height)
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

    @objc private func performReconnect() {
        reconnect?()
    }
}
