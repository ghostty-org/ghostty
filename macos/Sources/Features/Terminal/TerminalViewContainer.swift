import AppKit
import SwiftUI

/// Use this container to achieve a glass effect at the window level.
/// Modifying `NSThemeFrame` can sometimes be unpredictable.
class TerminalViewContainer<ViewModel: TerminalViewModel>: NSView {
    private let terminalView: NSView

    /// Combined glass effect and inactive tint overlay view
    private var glassEffectView: NSView?
    private var derivedConfig: DerivedConfig?

    init(ghostty: Ghostty.App, viewModel: ViewModel, delegate: (any TerminalViewDelegate)? = nil) {
        self.derivedConfig = DerivedConfig(config: ghostty.config, preferredBackgroundColor: nil, cornerRadius: nil)
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

    deinit {
        NotificationCenter.default.removeObserver(self)
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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: nil
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
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
        let newValue = DerivedConfig(config: config, preferredBackgroundColor: (window as? TerminalWindow)?.preferredBackgroundColor, cornerRadius: window?.defaultCornerRadius)
        guard newValue != derivedConfig else { return }
        derivedConfig = newValue

        // Add some delay to wait TerminalWindow to update first to ensure
        // that some of our properties are updated. This is a HACK to ensure
        // light/dark themes work, and we will come up with a better way
        // in the future.
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.05,
            execute: updateGlassEffectIfNeeded)
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window == self.window else { return }
        updateGlassTintOverlay(isKeyWindow: true)
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window == self.window else { return }
        updateGlassTintOverlay(isKeyWindow: false)
    }
}

// MARK: Glass

/// An `NSView` that contains a liquid glass background effect and
/// an inactive-window tint overlay.
#if compiler(>=6.2)
@available(macOS 26.0, *)
private class TerminalGlassView: NSView {
    private let glassEffectView: NSGlassEffectView
    private var topConstraint: NSLayoutConstraint!
    private let tintOverlay: NSView

    init(topOffset: CGFloat) {
        self.glassEffectView = NSGlassEffectView()
        self.tintOverlay = NSView()
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false

        // Glass effect view fills this view.
        glassEffectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glassEffectView)
        topConstraint = glassEffectView.topAnchor.constraint(
            equalTo: topAnchor,
            constant: topOffset
        )
        NSLayoutConstraint.activate([
            topConstraint,
            glassEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            glassEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // Tint overlay sits above the glass effect.
        tintOverlay.translatesAutoresizingMaskIntoConstraints = false
        tintOverlay.wantsLayer = true
        tintOverlay.alphaValue = 0
        addSubview(tintOverlay, positioned: .above, relativeTo: glassEffectView)

        NSLayoutConstraint.activate([
            tintOverlay.topAnchor.constraint(equalTo: glassEffectView.topAnchor),
            tintOverlay.leadingAnchor.constraint(equalTo: glassEffectView.leadingAnchor),
            tintOverlay.bottomAnchor.constraint(equalTo: glassEffectView.bottomAnchor),
            tintOverlay.trailingAnchor.constraint(equalTo: glassEffectView.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Configures the glass effect style, tint color, corner radius, and
    /// updates the inactive tint overlay based on window key status.
    func configure(
        style: NSGlassEffectView.Style,
        backgroundColor: NSColor,
        backgroundOpacity: Double,
        cornerRadius: CGFloat?,
        isKeyWindow: Bool
    ) {
        glassEffectView.style = style
        glassEffectView.tintColor = backgroundColor.withAlphaComponent(backgroundOpacity)
        if let cornerRadius {
            glassEffectView.cornerRadius = cornerRadius
        }
        updateKeyStatus(isKeyWindow, backgroundColor: backgroundColor)
    }

    /// Updates the top inset offset for both the glass effect and tint overlay.
    /// Call this when the safe area insets change (e.g., during layout).
    func updateTopInset(_ offset: CGFloat) {
        topConstraint.constant = offset
    }

    /// Updates the tint overlay visibility based on window key status.
    func updateKeyStatus(_ isKeyWindow: Bool, backgroundColor: NSColor) {
        let tint = tintProperties(for: backgroundColor)
        tintOverlay.layer?.backgroundColor = tint.color.cgColor
        tintOverlay.alphaValue = isKeyWindow ? 0 : tint.opacity
    }

    /// Computes a saturation-boosted tint color and opacity for the inactive overlay.
    private func tintProperties(for color: NSColor) -> (color: NSColor, opacity: CGFloat) {
        let isLight = color.isLightColor
        let vibrant = color.adjustingSaturation(by: 1.2)
        let overlayOpacity: CGFloat = isLight ? 0.35 : 0.85
        return (vibrant, overlayOpacity)
    }
}
#endif // compiler(>=6.2)

private extension TerminalViewContainer {
#if compiler(>=6.2)
    @available(macOS 26.0, *)
    func addGlassEffectViewIfNeeded() -> TerminalGlassView? {
        if let existed = glassEffectView as? TerminalGlassView {
            updateGlassEffectTopInsetIfNeeded()
            return existed
        }
        guard let themeFrameView = window?.contentView?.superview else {
            return nil
        }
        let effectView = TerminalGlassView(topOffset: -themeFrameView.safeAreaInsets.top)
        addSubview(effectView, positioned: .below, relativeTo: terminalView)
        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: topAnchor),
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
        guard #available(macOS 26.0, *), let derivedConfig else {
            glassEffectView?.removeFromSuperview()
            glassEffectView = nil
            return
        }
        guard let effectView = addGlassEffectViewIfNeeded() else {
            return
        }

        effectView.configure(
            style: derivedConfig.style.official,
            backgroundColor: derivedConfig.backgroundColor,
            backgroundOpacity: derivedConfig.backgroundOpacity,
            cornerRadius: derivedConfig.cornerRadius,
            isKeyWindow: window?.isKeyWindow ?? true
        )
#endif // compiler(>=6.2)
    }

    func updateGlassEffectTopInsetIfNeeded() {
#if compiler(>=6.2)
        guard
            #available(macOS 26.0, *),
            let effectView = glassEffectView as? TerminalGlassView,
            let themeFrameView = window?.contentView?.superview,
            let derivedConfig
        else {
            return
        }
        effectView.updateTopInset(-themeFrameView.safeAreaInsets.top)
#endif // compiler(>=6.2)
    }

    func updateGlassTintOverlay(isKeyWindow: Bool) {
#if compiler(>=6.2)
        guard
            #available(macOS 26.0, *),
            let effectView = glassEffectView as? TerminalGlassView,
            let derivedConfig
        else {
            return
        }
        effectView.updateKeyStatus(isKeyWindow, backgroundColor: derivedConfig.backgroundColor)
#endif // compiler(>=6.2)
    }

    struct DerivedConfig: Equatable {
        let style: BackportNSGlassStyle
        let backgroundColor: NSColor
        let backgroundOpacity: Double
        let cornerRadius: CGFloat?

        init?(config: Ghostty.Config, preferredBackgroundColor: NSColor?, cornerRadius: CGFloat?) {
            switch config.backgroundBlur {
            case .macosGlassRegular:
                style = .regular
            case .macosGlassClear:
                style = .clear
            default:
                return nil
            }
            self.backgroundColor = preferredBackgroundColor ?? NSColor(config.backgroundColor)
            self.backgroundOpacity = config.backgroundOpacity
            self.cornerRadius = cornerRadius
        }
    }
}
