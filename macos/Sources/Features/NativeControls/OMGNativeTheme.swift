import AppKit
import GhosttyKit

@MainActor
protocol OMGNativeThemeApplying: AnyObject {
    func applyTheme(_ theme: OMGNativeTheme)
}

/// One palette and state vocabulary for OMG-owned native surfaces and controls.
struct OMGNativeTheme: Equatable {
    let background: NSColor
    let foreground: NSColor
    let accent: NSColor
    var opacity: Double = 1
    var blur: Ghostty.Config.BackgroundBlur = .disabled

    init(background: NSColor, foreground: NSColor, accent: NSColor = .controlAccentColor) {
        self.background = background.withAlphaComponent(1)
        self.foreground = foreground
        self.accent = accent
    }

    var secondary: NSColor { foreground.withAlphaComponent(0.62) }
    var disabled: NSColor { foreground.withAlphaComponent(0.30) }
    var border: NSColor { foreground.withAlphaComponent(0.14) }
    var controlFill: NSColor { foreground.withAlphaComponent(0.045) }
    var hoverFill: NSColor { foreground.withAlphaComponent(0.09) }
    var selectedFill: NSColor { accent.withAlphaComponent(0.17) }
    var appearance: NSAppearance? { NSAppearance(named: background.isLightColor ? .aqua : .darkAqua) }

    @MainActor
    static func resolve(for window: NSWindow?, config: Ghostty.Config? = nil) -> OMGNativeTheme {
        let origin = window?.sheetParent ?? window
        let config = config ?? (origin?.windowController as? TerminalController)?.ghostty.config
            ?? (NSApp.delegate as? AppDelegate)?.ghostty.config
        guard let config else {
            var background = NSColor.windowBackgroundColor
            var foreground = NSColor.labelColor
            (origin?.effectiveAppearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
                background = background.usingColorSpace(.deviceRGB) ?? background
                foreground = foreground.usingColorSpace(.deviceRGB) ?? foreground
            }
            return .init(background: background, foreground: foreground)
        }
        let palette = OMGThemeBackground.palette(for: origin, config: config)
        let editor = config.editorTheme(background: palette.background)
        var theme = OMGNativeTheme(background: palette.background, foreground: palette.foreground, accent: editor.commands.color)
        let forceOpaque = origin?.styleMask.contains(.fullScreen) == true ||
            (origin?.windowController as? TerminalController)?.isBackgroundOpaque == true
        if !forceOpaque {
            theme.opacity = config.backgroundOpacity.clamped(to: 0...1)
            theme.blur = config.backgroundBlur
        }
        return theme
    }

    @MainActor
    static func resolve(for view: NSView) -> OMGNativeTheme {
        var parent = view.superview
        while let current = parent {
            if let surface = current as? OMGNativeSurfaceView { return surface.theme }
            parent = current.superview
        }
        return resolve(for: view.window)
    }
}

/// Explicit popup origin avoids guessing the active window after a sheet becomes key.
@MainActor
final class OMGNativeThemeObserver: NSObject {
    weak var sourceWindow: NSWindow?
    var onChange: ((OMGNativeTheme) -> Void)?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(configChanged(_:)),
                                               name: .ghosttyConfigDidChange, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func refresh() { onChange?(OMGNativeTheme.resolve(for: sourceWindow)) }

    @objc private func configChanged(_ notification: Notification) {
        if let object = notification.object as AnyObject? {
            guard object === sourceWindow || object === sourceWindow?.windowController else { return }
        }
        let config = notification.userInfo?[Notification.Name.GhosttyConfigChangeKey] as? Ghostty.Config
        onChange?(OMGNativeTheme.resolve(for: sourceWindow, config: config))
    }
}

class OMGNativeSurfaceView: NSView {
    private let themeObserver = OMGNativeThemeObserver()
    private(set) var theme = OMGNativeTheme(background: .windowBackgroundColor, foreground: .labelColor)
    var onThemeChange: ((OMGNativeTheme) -> Void)?
    private var hasExplicitSource = false
    private var backdrop: NSView?
    private var backdropBlur: Ghostty.Config.BackgroundBlur?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        themeObserver.onChange = { [weak self] in self?.applyTheme($0) }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var wantsUpdateLayer: Bool { true }

    func bindTheme(to window: NSWindow?) {
        hasExplicitSource = true
        themeObserver.sourceWindow = window
        themeObserver.refresh()
    }

    func applyTheme(_ theme: OMGNativeTheme) {
        self.theme = theme
        appearance = theme.appearance
        needsDisplay = true
        updateBackdrop()
        func update(_ parent: NSView) {
            for child in parent.subviews {
                if child === backdrop { continue }
                if let customized = child as? OMGNativeThemeApplying {
                    customized.applyTheme(theme)
                    continue
                }
                if let surface = child as? OMGNativeSurfaceView {
                    surface.applyTheme(theme)
                    continue
                }
                if let button = child as? NativeActionControl { button.applyTheme(theme) }
                if let search = child as? OMGNativeSearchField { search.applyTheme(theme) }
                if let field = child as? NSTextField, !(field is NSSearchField) {
                    // Preserve semantic error/warning/success colors owned by a form.
                    if ![NSColor.systemRed, .systemOrange, .systemGreen].contains(where: { $0 == field.textColor }) {
                        field.textColor = theme.foreground
                    }
                    if field.isEditable { field.backgroundColor = theme.background; field.focusRingType = .none }
                }
                child.needsDisplay = true
                update(child)
            }
        }
        update(self)
        onThemeChange?(theme)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if !hasExplicitSource { themeObserver.sourceWindow = window }
        themeObserver.refresh()
    }

    @objc private func accessibilityChanged() { updateBackdrop(); needsDisplay = true }

    var effectiveOpacity: Double { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : theme.opacity }

    private func updateBackdrop() {
        let blur: Ghostty.Config.BackgroundBlur = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ||
            (effectiveOpacity >= 1 && !theme.blur.isGlassStyle) ? .disabled : theme.blur
        if backdropBlur != blur {
            backdrop?.removeFromSuperview()
            backdrop = nil
            backdropBlur = blur
#if compiler(>=6.2)
            if #available(macOS 26.0, *), blur.isGlassStyle {
                backdrop = TerminalGlassView(topOffset: 0)
            }
#endif
            if let backdrop {
                backdrop.frame = bounds
                backdrop.autoresizingMask = [.width, .height]
                addSubview(backdrop, positioned: .below, relativeTo: nil)
            }
        }
#if compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = backdrop as? TerminalGlassView {
            glass.configure(style: blur == .macosGlassClear ? .clear : .regular,
                            backgroundColor: theme.background, backgroundOpacity: effectiveOpacity,
                            cornerRadius: 0, isKeyWindow: window?.isKeyWindow ?? true)
        }
#endif
        // Only configure an auxiliary window owned by this surface, never its terminal origin.
        if let window, window.contentViewController?.view === self ||
            (hasExplicitSource && window !== themeObserver.sourceWindow) {
            window.isOpaque = effectiveOpacity >= 1
            window.backgroundColor = effectiveOpacity >= 1 ? theme.background : .clear
            if !blur.isGlassStyle, let app = (NSApp.delegate as? AppDelegate)?.ghostty.app {
                ghostty_set_window_background_blur(app, Unmanaged.passUnretained(window).toOpaque())
            }
        }
    }

    override func updateLayer() {
        layer?.backgroundColor = (backdrop == nil ? theme.background.withAlphaComponent(effectiveOpacity) : .clear).cgColor
    }
}

class OMGNativeSearchField: NSSearchField {
    private(set) var theme = OMGNativeTheme(background: .windowBackgroundColor, foreground: .labelColor)
    private let themeObserver = OMGNativeThemeObserver()
    private var hovered = false
    private var tracking: NSTrackingArea?
    var isInputFocused: Bool { currentEditor() != nil }
    override var alignmentRectInsets: NSEdgeInsets { .init(top: 0, left: 0, bottom: 0, right: 0) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = OMGNativeSearchCell(textCell: "")
        isEditable = true
        isSelectable = true
        isBezeled = true
        drawsBackground = false
        focusRingType = .none
        controlSize = .small
        font = .systemFont(ofSize: 11)
        sendsSearchStringImmediately = true
        sendsWholeSearchString = false
        themeObserver.onChange = { [weak self] in self?.applyTheme($0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyTheme(_ theme: OMGNativeTheme) {
        self.theme = theme
        textColor = theme.foreground
        if let placeholder = placeholderAttributedString?.string ?? placeholderString {
            placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
                .font: font ?? NSFont.systemFont(ofSize: 11), .foregroundColor: theme.secondary,
            ])
        }
        (currentEditor() as? NSTextView)?.textColor = theme.foreground
        (currentEditor() as? NSTextView)?.drawsBackground = false
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        themeObserver.sourceWindow = window
        applyTheme(.resolve(for: self))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        tracking = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        needsDisplay = true
        return result
    }

    fileprivate func drawSurface(in rect: NSRect) {
        let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        (hovered && isEnabled ? theme.hoverFill : theme.controlFill).setFill()
        shape.fill()
        (isInputFocused ? theme.accent.withAlphaComponent(0.5) : theme.border).setStroke()
        shape.lineWidth = isInputFocused ? 1 : 0.5
        shape.stroke()
    }
}

private final class OMGNativeSearchCell: NSSearchFieldCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        (controlView as? OMGNativeSearchField)?.drawSurface(in: cellFrame)
        super.drawInterior(withFrame: cellFrame, in: controlView)
    }
}
