import AppKit
import SwiftUI

/// Use this container to achieve a glass effect at the window level.
/// Modifying `NSThemeFrame` can sometimes be unpredictable.
class TerminalViewContainer: NSView {
    private let terminalView: NSView
    private var sidebarView: NSView?
    private var sidebarWidth: CGFloat = 0
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var terminalLeadingConstraint: NSLayoutConstraint?
    private var terminalLeadingSidebarConstraint: NSLayoutConstraint?
    private var sidebarResizeHandle: SidebarResizeHandle?

    /// Combined glass effect and inactive tint overlay view
    private(set) var glassEffectView: NSView?
    private var derivedConfig: DerivedConfig?

    var windowThemeFrameView: NSView? {
        window?.contentView?.superview
    }

    var windowCornerRadius: CGFloat? {
        guard let window, window.responds(to: Selector(("_cornerRadius"))) else {
            return nil
        }

        return window.value(forKey: "_cornerRadius") as? CGFloat
    }

    var currentSidebarWidth: CGFloat {
        guard sidebarView != nil else { return 0 }

        let layoutWidth = sidebarView?.frame.width ?? 0
        return layoutWidth > 0 ? layoutWidth : sidebarWidth
    }

    init<Root: View>(@ViewBuilder rootView: () -> Root) {
        self.terminalView = NSHostingView(rootView: rootView())
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The initial content size to use as a fallback before the SwiftUI
    /// view hierarchy has completed layout (i.e. before @FocusedValue
    /// propagates `lastFocusedSurface`). Once the hosting view reports
    /// a valid intrinsic size, this fallback is no longer used.
    var initialContentSize: NSSize?

    override var intrinsicContentSize: NSSize {
        let hostingSize = terminalView.intrinsicContentSize
        // The hosting view returns a valid size once SwiftUI has laid out
        // with the correct idealWidth/idealHeight. Before that (when
        // @FocusedValue hasn't propagated), it returns a tiny default.
        // Fall back to initialContentSize in that case.
        let terminalSize: NSSize
        if let initialContentSize,
           hostingSize.width < initialContentSize.width || hostingSize.height < initialContentSize.height {
            terminalSize = initialContentSize
        } else {
            terminalSize = hostingSize
        }

        return NSSize(
            width: terminalSize.width + sidebarWidth,
            height: terminalSize.height)
    }

    private func setup() {
        addSubview(terminalView)
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        let leadingConstraint = terminalView.leadingAnchor.constraint(equalTo: leadingAnchor)
        terminalLeadingConstraint = leadingConstraint
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            leadingConstraint,
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    func installSidebar(_ sidebar: NSView, width: CGFloat) {
        guard sidebarView !== sidebar else {
            setSidebarWidth(width, propagateToTabGroup: false)
            syncSidebarTitlebarWidth()
            return
        }

        sidebarView?.removeFromSuperview()
        sidebarResizeHandle?.removeFromSuperview()
        sidebarView = sidebar
        setSidebarWidth(width, propagateToTabGroup: false)

        addSubview(sidebar)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        terminalLeadingConstraint?.isActive = false
        let terminalToSidebar = terminalView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor)
        let widthConstraint = sidebar.widthAnchor.constraint(equalToConstant: sidebarWidth)
        terminalLeadingSidebarConstraint = terminalToSidebar
        sidebarWidthConstraint = widthConstraint

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthConstraint,
            sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: TerminalSidebarController.minWidth),
            sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: TerminalSidebarController.maxWidth),
            terminalToSidebar,
        ])

        let resizeHandle = SidebarResizeHandle(container: self)
        sidebarResizeHandle = resizeHandle
        addSubview(resizeHandle, positioned: .above, relativeTo: sidebar)
        NSLayoutConstraint.activate([
            resizeHandle.centerXAnchor.constraint(equalTo: sidebar.trailingAnchor),
            resizeHandle.topAnchor.constraint(equalTo: topAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: bottomAnchor),
            resizeHandle.widthAnchor.constraint(equalToConstant: 8),
        ])

        invalidateIntrinsicContentSize()
        syncSidebarTitlebarWidth()
    }

    func removeSidebar() {
        guard let sidebarView else { return }

        sidebarView.removeFromSuperview()
        sidebarResizeHandle?.removeFromSuperview()
        self.sidebarView = nil
        sidebarResizeHandle = nil
        sidebarWidth = 0
        sidebarWidthConstraint = nil
        terminalLeadingSidebarConstraint?.isActive = false
        terminalLeadingSidebarConstraint = nil
        terminalLeadingConstraint?.isActive = true

        invalidateIntrinsicContentSize()
        (window as? TerminalWindow)?.removeSidebarTitlebarBackground()
    }

    fileprivate func resizeSidebar(by deltaX: CGFloat) {
        setSidebarWidth(sidebarWidth + deltaX, propagateToTabGroup: true)
        sidebarWidthConstraint?.constant = sidebarWidth
        layoutSubtreeIfNeeded()
    }

    func resizeSidebarFromTitlebar(by deltaX: CGFloat) {
        resizeSidebar(by: deltaX)
    }

    func syncSidebarTitlebarWidth() {
        guard sidebarView != nil else { return }

        let width = clampedSidebarWidth(currentSidebarWidth)
        (window as? TerminalWindow)?.setSidebarTitlebarWidth(width)
    }

    private func setSidebarWidth(_ width: CGFloat, propagateToTabGroup: Bool) {
        sidebarWidth = clampedSidebarWidth(width)
        TerminalSidebarController.setPreferredWidth(sidebarWidth)
        sidebarWidthConstraint?.constant = sidebarWidth
        invalidateIntrinsicContentSize()
        (window as? TerminalWindow)?.setSidebarTitlebarWidth(sidebarWidth)

        if propagateToTabGroup {
            syncSidebarWidthAcrossTabGroup()
        }
    }

    private func clampedSidebarWidth(_ width: CGFloat) -> CGFloat {
        min(
            max(width, TerminalSidebarController.minWidth),
            TerminalSidebarController.maxWidth)
    }

    private func syncSidebarWidthAcrossTabGroup() {
        guard let windows = window?.tabGroup?.windows else { return }

        for window in windows where window.contentView !== self {
            guard let container = window.contentView as? TerminalViewContainer else {
                continue
            }

            container.setSidebarWidth(sidebarWidth, propagateToTabGroup: false)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateGlassEffectIfNeeded()
        updateGlassEffectTopInsetIfNeeded()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let sidebarResizeHandle {
            let handlePoint = convert(point, to: sidebarResizeHandle)
            if sidebarResizeHandle.bounds.contains(handlePoint) {
                return sidebarResizeHandle
            }
        }

        return super.hitTest(point)
    }

    override func layout() {
        super.layout()
        updateGlassEffectTopInsetIfNeeded()
        syncSidebarTitlebarWidth()
    }

    func ghosttyConfigDidChange(_ config: Ghostty.Config, preferredBackgroundColor: NSColor?) {
        let newValue = DerivedConfig(config: config, preferredBackgroundColor: preferredBackgroundColor, cornerRadius: windowCornerRadius)
        guard newValue != derivedConfig else { return }
        derivedConfig = newValue
        DispatchQueue.main.async(execute: updateGlassEffectIfNeeded)
    }
}

// MARK: - BaseTerminalController + terminalViewContainer

extension BaseTerminalController {
    var terminalViewContainer: TerminalViewContainer? {
        window?.contentView as? TerminalViewContainer
    }
}

private final class SidebarResizeHandle: NSView {
    private weak var container: TerminalViewContainer?
    private var lastMouseX: CGFloat?

    init(container: TerminalViewContainer) {
        self.container = container
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        lastMouseX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        let currentX = event.locationInWindow.x
        let previousX = lastMouseX ?? currentX
        lastMouseX = currentX
        container?.resizeSidebar(by: currentX - previousX)
    }

    override func mouseUp(with event: NSEvent) {
        lastMouseX = nil
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
        glassEffectView.cornerRadius = cornerRadius ?? 0
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

extension TerminalViewContainer {
#if compiler(>=6.2)
    @available(macOS 26.0, *)
    private func addGlassEffectViewIfNeeded() -> TerminalGlassView? {
        if let existed = glassEffectView as? TerminalGlassView {
            updateGlassEffectTopInsetIfNeeded()
            return existed
        }
        guard let themeFrameView = windowThemeFrameView else {
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

    private func updateGlassEffectIfNeeded() {
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

    private func updateGlassEffectTopInsetIfNeeded() {
#if compiler(>=6.2)
        guard
            #available(macOS 26.0, *),
            let effectView = glassEffectView as? TerminalGlassView,
            let themeFrameView = windowThemeFrameView
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
