import AppKit
import SwiftUI

/// Use this container to achieve a glass effect at the window level.
/// Modifying `NSThemeFrame` can sometimes be unpredictable.
class TerminalViewContainer<ViewModel: TerminalViewModel>: NSView {
    private let terminalView: NSView
    private let terminalContainer: NSView
    private let fallbackEffectView: NSVisualEffectView
    private let fallbackTintView: NSView

    /// Glass effect view for liquid glass background when transparency is enabled
    private var glassEffectView: NSView?
    private var glassTopConstraint: NSLayoutConstraint?
    private var derivedConfig: DerivedConfig
    private var windowObservers: [NSObjectProtocol] = []

    init(ghostty: Ghostty.App, viewModel: ViewModel, delegate: (any TerminalViewDelegate)? = nil) {
        self.derivedConfig = DerivedConfig(config: ghostty.config)
        self.terminalView = NSHostingView(rootView: TerminalView(
            ghostty: ghostty,
            viewModel: viewModel,
            delegate: delegate
        ))
        self.terminalContainer = NSView()
        self.fallbackEffectView = NSVisualEffectView()
        self.fallbackTintView = NSView()
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.removeAll()
    }

    /// To make ``TerminalController/DefaultSize/contentIntrinsicSize``
    /// work in ``TerminalController/windowDidLoad()``,
    /// we override this to provide the correct size.
    override var intrinsicContentSize: NSSize {
        terminalView.intrinsicContentSize
    }

    private func setup() {
        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        fallbackEffectView.translatesAutoresizingMaskIntoConstraints = false
        fallbackEffectView.material = .underWindowBackground
        fallbackEffectView.blendingMode = .behindWindow
        fallbackEffectView.state = .active
        fallbackEffectView.isHidden = true
        fallbackTintView.translatesAutoresizingMaskIntoConstraints = false
        fallbackTintView.wantsLayer = true
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalContainer)
        terminalContainer.addSubview(fallbackEffectView)
        fallbackEffectView.addSubview(fallbackTintView)
        terminalContainer.addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalContainer.topAnchor.constraint(equalTo: topAnchor),
            terminalContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            fallbackEffectView.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
            fallbackEffectView.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
            fallbackEffectView.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),
            fallbackEffectView.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
            fallbackTintView.topAnchor.constraint(equalTo: fallbackEffectView.topAnchor),
            fallbackTintView.leadingAnchor.constraint(equalTo: fallbackEffectView.leadingAnchor),
            fallbackTintView.bottomAnchor.constraint(equalTo: fallbackEffectView.bottomAnchor),
            fallbackTintView.trailingAnchor.constraint(equalTo: fallbackEffectView.trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),
            terminalView.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
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
        updateWindowObservers()
        updateGlassEffectIfNeeded()
        updateGlassEffectTopInsetIfNeeded()
    }

    override func layout() {
        super.layout()
        updateGlassEffectTopInsetIfNeeded()
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
            updateGlassEffectTopInsetIfNeeded()
            return existed
        }
        guard window != nil else { return nil }
        let effectView = NSGlassEffectView()
        if terminalContainer.superview === self {
            addSubview(effectView, positioned: .below, relativeTo: terminalContainer)
        } else {
            addSubview(effectView)
        }
        effectView.translatesAutoresizingMaskIntoConstraints = false
        glassTopConstraint = effectView.topAnchor.constraint(
            equalTo: topAnchor,
            constant: -titlebarInset()
        )
        if let glassTopConstraint {
            NSLayoutConstraint.activate([
                glassTopConstraint,
                effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
                effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
                effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
        glassEffectView = effectView
        return effectView
    }
#endif // compiler(>=6.2)

    func updateGlassEffectIfNeeded() {
#if compiler(>=6.2)
        if #available(macOS 26.0, *), derivedConfig.backgroundBlur.isGlassStyle {
            guard let effectView = addGlassEffectViewIfNeeded() else {
                updateFallbackForWindowState()
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
            updateFallbackBackground(baseColor: backgroundColor)
            if let window, window.responds(to: Selector(("_cornerRadius"))), let cornerRadius = window.value(forKey: "_cornerRadius") as? CGFloat {
                effectView.cornerRadius = cornerRadius
            }
            updateFallbackForWindowState()
            return
        }
        glassEffectView?.removeFromSuperview()
        glassEffectView = nil
        glassTopConstraint = nil
        updateFallbackForWindowState()
#endif // compiler(>=6.2)
    }

    func updateGlassEffectTopInsetIfNeeded() {
#if compiler(>=6.2)
        let inset = titlebarInset()
        if #available(macOS 26.0, *), derivedConfig.backgroundBlur.isGlassStyle {
            glassTopConstraint?.constant = -inset
        }
#endif // compiler(>=6.2)
    }

    func titlebarInset() -> CGFloat {
        guard let window else { return 0 }
        if let themeFrameView = window.contentView?.superview {
            let safeInset = themeFrameView.safeAreaInsets.top
            if safeInset > 0 {
                return safeInset
            }
        }
        let inset = window.frame.height - window.contentLayoutRect.height
        return max(inset, 0)
    }

    func updateFallbackBackground(baseColor: NSColor? = nil) {
        let backgroundColor = baseColor ?? (window as? TerminalWindow)?.preferredBackgroundColor ?? NSColor(derivedConfig.backgroundColor)
        fallbackTintView.layer?.backgroundColor = backgroundColor
            .withAlphaComponent(derivedConfig.backgroundOpacity)
            .cgColor
    }

    func updateFallbackForWindowState() {
        updateFallbackBackground()
        guard derivedConfig.backgroundBlur.isGlassStyle else {
            fallbackEffectView.isHidden = true
            return
        }
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let isKeyWindow = window?.isKeyWindow ?? true
            let hasGlass = glassEffectView != nil
            fallbackEffectView.isHidden = isKeyWindow && hasGlass
            return
        }
#endif // compiler(>=6.2)
        fallbackEffectView.isHidden = true
    }

    func updateWindowObservers() {
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.removeAll()
        guard let window else { return }
        let center = NotificationCenter.default
        windowObservers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.updateFallbackForWindowState()
        })
        windowObservers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.updateFallbackForWindowState()
        })
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
