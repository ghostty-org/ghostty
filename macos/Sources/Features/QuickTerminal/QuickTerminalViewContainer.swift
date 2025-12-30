import AppKit
import SwiftUI

/// Container for QuickTerminalView that provides glass effect support at the window level.
/// This mirrors TerminalViewContainer but wraps QuickTerminalView to include tab bar functionality.
class QuickTerminalViewContainer: NSView {
    private let terminalView: NSView

    private var derivedConfig: DerivedConfig

    init(ghostty: Ghostty.App, controller: QuickTerminalController, tabManager: QuickTerminalTabManager) {
        self.derivedConfig = DerivedConfig(config: ghostty.config)
        self.terminalView = NSHostingView(rootView: QuickTerminalView(
            ghostty: ghostty,
            controller: controller,
            tabManager: tabManager
        ))
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// To make content sizing work properly, we override this to provide the correct size.
    override var intrinsicContentSize: NSSize {
        terminalView.intrinsicContentSize
    }

    private func setup() {
        addSubview(terminalView)
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ghosttyConfigDidChange(_:)),
            name: .ghosttyConfigDidChange,
            object: nil
        )
    }

    @objc private func ghosttyConfigDidChange(_ notification: Notification) {
        guard let config = notification.userInfo?[
            Notification.Name.GhosttyConfigChangeKey
        ] as? Ghostty.Config else { return }
        let newValue = DerivedConfig(config: config)
        guard newValue != derivedConfig else { return }
        derivedConfig = newValue
        DispatchQueue.main.async(execute: updateGlassEffectIfNeeded)
    }
}
