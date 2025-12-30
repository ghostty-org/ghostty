import AppKit
import SwiftUI

/// Use this container to achieve a glass effect at the window level.
/// Modifying `NSThemeFrame` can sometimes be unpredictable.
class TerminalViewContainer<ViewModel: TerminalViewModel>: NSView {
    private let terminalView: NSView

    /// Glass effect view for liquid glass background when transparency is enabled
    private var glassEffectView: NSView?
    private var derivedConfig: DerivedConfig

    init(ghostty: Ghostty.App, viewModel: ViewModel, delegate: (any TerminalViewDelegate)? = nil) {
        self.derivedConfig = DerivedConfig(config: ghostty.config)
        self.terminalView = NSHostingView(rootView: TerminalView(
            ghostty: ghostty,
            viewModel: viewModel,
            delegate: delegate
        ))
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// To make ``TerminalController/DefaultSize/contentIntrinsicSize``
    /// work in ``TerminalController/windowDidLoad()``,
    /// we override this to provide the correct size.
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateGlassEffectIfNeeded()
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

// MARK: Glass

private extension TerminalViewContainer {
#if compiler(>=6.2)
    @available(macOS 26.0, *)
    func addGlassEffectViewIfNeeded() -> NSGlassEffectView? {
        if let existed = glassEffectView as? NSGlassEffectView {
            return existed
        }
        guard let themeFrameView = window?.contentView?.superview else {
            return nil
        }
        let effectView = NSGlassEffectView()
        addSubview(effectView, positioned: .below, relativeTo: terminalView)
        effectView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: topAnchor, constant: -themeFrameView.safeAreaInsets.top),
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        glassEffectView = effectView
        return effectView
    }
#endif // compiler(>=6.2)

    func updateGlassEffectIfNeeded() {
#if compiler(>=6.2)
        guard #available(macOS 26.0, *), derivedConfig.backgroundBlur.isGlassStyle else {
            glassEffectView?.removeFromSuperview()
            glassEffectView = nil
            return
        }
        guard let effectView = addGlassEffectViewIfNeeded() else {
            return
        }
        switch derivedConfig.backgroundBlur {
        case .macosGlassRegular:
            effectView.style = NSGlassEffectView.Style.regular
        case .macosGlassClear:
            effectView.style = NSGlassEffectView.Style.clear
        default:
            break
        }
        let backgroundColor = (window as? TerminalWindow)?.preferredBackgroundColor ?? NSColor(derivedConfig.backgroundColor)
        effectView.tintColor = backgroundColor
            .withAlphaComponent(derivedConfig.backgroundOpacity)
        if let window, window.responds(to: Selector(("_cornerRadius"))), let cornerRadius = window.value(forKey: "_cornerRadius") as? CGFloat {
            effectView.cornerRadius = cornerRadius
        }
#endif // compiler(>=6.2)
    }

    struct DerivedConfig: Equatable {
        var backgroundOpacity: Double = 0
        var backgroundBlur: Ghostty.Config.BackgroundBlur
        var backgroundColor: Color = .clear

        init(config: Ghostty.Config) {
            self.backgroundBlur = config.backgroundBlur
            self.backgroundOpacity = config.backgroundOpacity
            self.backgroundColor = config.backgroundColor
        }
    }
}
