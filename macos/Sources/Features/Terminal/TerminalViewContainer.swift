import AppKit
import Combine
import SwiftUI

/// Use this container to achieve a glass effect at the window level.
/// Modifying `NSThemeFrame` can sometimes be unpredictable.
class TerminalViewContainer: NSView {
    private let terminalView: NSView

    /// The vertical tab sidebar on the leading edge, if this container has one.
    let tabSidebar: TabSidebarView?

    /// The bar above the terminal showing the tab title. Only present with a sidebar.
    let titleStrip: TerminalTitleStripView?

    /// The pane on the trailing edge previewing a file of the file explorer. Only present
    /// with a sidebar.
    let filePreview: FilePreviewView?

    /// The width constraint of the tab sidebar, updated on layout.
    private var sidebarWidthConstraint: NSLayoutConstraint?

    /// The width constraint of the file preview, updated on layout.
    private var previewWidthConstraint: NSLayoutConstraint?

    /// Subscriptions to the shared tab sidebar settings.
    private var sidebarCancellables: Set<AnyCancellable> = []

    /// Background color applied with glass effect
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

    init<Root: View>(
        sidebar: TabSidebarView? = nil,
        titleStrip: TerminalTitleStripView? = nil,
        @ViewBuilder rootView: () -> Root
    ) {
        self.terminalView = NSHostingView(rootView: rootView())
        self.tabSidebar = sidebar
        self.titleStrip = sidebar == nil ? nil : titleStrip
        self.filePreview = sidebar == nil ? nil : FilePreviewView()
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
        // The sidebar is added on top of the terminal size so that configured
        // sizes such as `window-width` still describe the terminal itself.
        var size = terminalIntrinsicContentSize
        if size.width != NSView.noIntrinsicMetric {
            size.width += sidebarIntrinsicWidth
        }
        if size.height != NSView.noIntrinsicMetric, titleStrip != nil {
            size.height += TerminalTitleStripView.contentHeight
        }
        return size
    }

    private var terminalIntrinsicContentSize: NSSize {
        let hostingSize = terminalView.intrinsicContentSize
        // The hosting view returns a valid size once SwiftUI has laid out
        // with the correct idealWidth/idealHeight. Before that (when
        // @FocusedValue hasn't propagated), it returns a tiny default.
        // Fall back to initialContentSize in that case.
        if let initialContentSize,
           hostingSize.width < initialContentSize.width || hostingSize.height < initialContentSize.height {
            return initialContentSize
        }
        return hostingSize
    }

    /// The width the sidebar would like to have, ignoring the container size.
    private var sidebarIntrinsicWidth: CGFloat {
        guard tabSidebar != nil else { return 0 }
        let settings = TabSidebarSettings.shared
        return settings.isVisible ? settings.width : 0
    }

    private func setup() {
        addSubview(terminalView)
        terminalView.translatesAutoresizingMaskIntoConstraints = false

        guard let tabSidebar else {
            NSLayoutConstraint.activate([
                terminalView.topAnchor.constraint(equalTo: topAnchor),
                terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
                terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
                terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            return
        }

        addSubview(tabSidebar)
        tabSidebar.translatesAutoresizingMaskIntoConstraints = false

        // We start the sidebar below the titlebar (if the content extends into it)
        // so that rows never sit beneath the traffic lights.
        let widthConstraint = tabSidebar.widthAnchor.constraint(equalToConstant: 0)
        sidebarWidthConstraint = widthConstraint
        NSLayoutConstraint.activate([
            tabSidebar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            tabSidebar.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabSidebar.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthConstraint,
            terminalView.leadingAnchor.constraint(equalTo: tabSidebar.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // The file preview sits on the trailing edge, collapsed until a file is previewed.
        // Like the title bar it extends up under the (transparent) titlebar.
        let trailingEdge: NSLayoutXAxisAnchor
        if let filePreview {
            addSubview(filePreview)
            filePreview.translatesAutoresizingMaskIntoConstraints = false
            filePreview.isHidden = true
            filePreview.onClose = { [weak self] in self?.closeFilePreview() }
            let previewWidth = filePreview.widthAnchor.constraint(equalToConstant: 0)
            previewWidthConstraint = previewWidth
            NSLayoutConstraint.activate([
                filePreview.topAnchor.constraint(equalTo: topAnchor),
                filePreview.bottomAnchor.constraint(equalTo: bottomAnchor),
                filePreview.trailingAnchor.constraint(equalTo: trailingAnchor),
                previewWidth,
            ])
            trailingEdge = filePreview.leadingAnchor
        } else {
            trailingEdge = trailingAnchor
        }
        terminalView.trailingAnchor.constraint(equalTo: trailingEdge).isActive = true

        // The title bar sits right above the terminal. It extends up under the
        // (transparent) titlebar so there is no gap, but its content is below it.
        if let titleStrip {
            addSubview(titleStrip)
            titleStrip.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                titleStrip.topAnchor.constraint(equalTo: topAnchor),
                titleStrip.leadingAnchor.constraint(equalTo: tabSidebar.trailingAnchor),
                titleStrip.trailingAnchor.constraint(equalTo: trailingEdge),
                titleStrip.bottomAnchor.constraint(
                    equalTo: safeAreaLayoutGuide.topAnchor,
                    constant: TerminalTitleStripView.contentHeight),
                terminalView.topAnchor.constraint(equalTo: titleStrip.bottomAnchor),
            ])
        } else {
            terminalView.topAnchor.constraint(equalTo: topAnchor).isActive = true
        }

        // Keep every window in sync with the shared sidebar settings. Note that
        // @Published emits before the property changes so we use the emitted values.
        let settings = TabSidebarSettings.shared
        settings.$isVisible
            .combineLatest(settings.$width)
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] visible, width in
                self?.tabSidebarSettingsDidChange(visible: visible, width: width)
            }
            .store(in: &sidebarCancellables)
        settings.$previewWidth
            .removeDuplicates()
            .sink { [weak self] width in
                self?.updatePreviewWidthConstraint(width: width)
            }
            .store(in: &sidebarCancellables)
    }

    private func tabSidebarSettingsDidChange(visible: Bool, width: CGFloat) {
        guard let tabSidebar else { return }
        tabSidebar.isHidden = !visible
        updateSidebarWidthConstraint(visible: visible, width: width)
        invalidateIntrinsicContentSize()

        // If the sidebar is hidden while it is being edited, then the terminal must
        // get focus back.
        if !visible { tabSidebar.sidebarDidHide() }
    }

    private func updateSidebarWidthConstraint(visible: Bool? = nil, width: CGFloat? = nil) {
        guard let sidebarWidthConstraint else { return }
        let settings = TabSidebarSettings.shared
        let effective = min(bounds.width, TabSidebarLogic.effectiveWidth(
            stored: width ?? settings.width,
            containerWidth: bounds.width,
            visible: visible ?? settings.isVisible))
        if sidebarWidthConstraint.constant != effective {
            sidebarWidthConstraint.constant = effective
        }
    }

    private func updatePreviewWidthConstraint(width: CGFloat? = nil) {
        guard let filePreview, let previewWidthConstraint else { return }
        let available = bounds.width - (sidebarWidthConstraint?.constant ?? 0)
        let effective = filePreview.isHidden ? 0 : FileExplorerLogic.effectivePreviewWidth(
            stored: width ?? TabSidebarSettings.shared.previewWidth,
            available: available)
        if previewWidthConstraint.constant != effective {
            previewWidthConstraint.constant = effective
        }
    }

    // MARK: File Preview

    /// Shows the given file in the preview pane. The terminal keeps focus.
    func showFilePreview(_ url: URL) {
        guard let filePreview else { return }
        filePreview.show(url)
        filePreview.isHidden = false
        updatePreviewWidthConstraint()
    }

    /// Closes the preview pane and gives focus back to the terminal.
    func closeFilePreview() {
        guard let filePreview, !filePreview.isHidden else { return }
        filePreview.isHidden = true
        filePreview.clear()
        updatePreviewWidthConstraint()

        if let surface = (window?.windowController as? BaseTerminalController)?.focusedSurface {
            window?.makeFirstResponder(surface)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateGlassEffectIfNeeded()
        updateGlassEffectTopInsetIfNeeded()
    }

    override func layout() {
        updateSidebarWidthConstraint()
        updatePreviewWidthConstraint()
        super.layout()
        updateGlassEffectTopInsetIfNeeded()
    }

    func ghosttyConfigDidChange(_ config: Ghostty.Config, preferredBackgroundColor: NSColor?) {
        tabSidebar?.updateAppearance(backgroundColor: preferredBackgroundColor ?? NSColor(config.backgroundColor))
        titleStrip?.updateAppearance(backgroundColor: preferredBackgroundColor ?? NSColor(config.backgroundColor))
        filePreview?.updateAppearance(backgroundColor: preferredBackgroundColor ?? NSColor(config.backgroundColor))

        let newValue = DerivedConfig(config: config, preferredBackgroundColor: preferredBackgroundColor, cornerRadius: windowCornerRadius)
        guard newValue != derivedConfig else { return }
        derivedConfig = newValue

        // Attach the glass effect synchronously if missing to prevent flicker when a new tab appears.
        // Existing updates remain deferred, as they can occur during SwiftUI rendering.
        if glassEffectView == nil {
            updateGlassEffectIfNeeded()
        } else {
            DispatchQueue.main.async(execute: updateGlassEffectIfNeeded)
        }
    }
}

// MARK: - BaseTerminalController + terminalViewContainer

extension BaseTerminalController {
    var terminalViewContainer: TerminalViewContainer? {
        window?.contentView as? TerminalViewContainer
    }
}

// MARK: Glass

/// An `NSView` that contains a liquid glass background effect and
/// an inactive-window tint overlay.
#if compiler(>=6.2)
@available(macOS 26.0, *)
private class TerminalGlassView: NSView, ObservableObject {
    /// We use this to apply glass effect to background colors
    ///
    struct GlassBackground: View {
        @ObservedObject var model: GlassViewModel

        var body: some View {
            model.color
                .glassEffect(
                    model.glass,
                    in: RoundedRectangle(cornerRadius: model.cornerRadius)
                )
        }
    }

    class GlassViewModel: ObservableObject {
        @Published var backgroundColor: Color = .clear
        @Published var backgroundOpacity: Double = 0
        @Published var cornerRadius: CGFloat = 0
        @Published var glass: Glass = .identity

        /// backgroundColor applied with backgroundOpacity
        var color: Color {
            backgroundColor.opacity(backgroundOpacity)
        }
    }

    private let glassEffectView: NSView
    private var topConstraint: NSLayoutConstraint!
    private let glassViewModel: GlassViewModel

    init(topOffset: CGFloat) {
        let viewModel = GlassViewModel()
        self.glassEffectView = NSHostingView(rootView: GlassBackground(model: viewModel))
        self.glassViewModel = viewModel
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Configures the glass, tint color, corner radius.
    func configure(
        glass: Glass,
        backgroundColor: NSColor,
        backgroundOpacity: Double,
        cornerRadius: CGFloat?,
    ) {
        glassViewModel.backgroundColor = Color(backgroundColor)
        glassViewModel.backgroundOpacity = backgroundOpacity
        glassViewModel.cornerRadius = cornerRadius ?? 0
        glassViewModel.glass = glass
    }

    /// Updates the top inset offset for both the glass effect and tint overlay.
    /// Call this when the safe area insets change (e.g., during layout).
    func updateTopInset(_ offset: CGFloat) {
        topConstraint.constant = offset
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
            glass: derivedConfig.glass.official,
            backgroundColor: derivedConfig.backgroundColor,
            backgroundOpacity: derivedConfig.backgroundOpacity,
            cornerRadius: derivedConfig.cornerRadius,
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

    struct DerivedConfig: Equatable {
        let glass: BackportGlass
        let backgroundColor: NSColor
        let backgroundOpacity: Double
        let cornerRadius: CGFloat?

        init?(config: Ghostty.Config, preferredBackgroundColor: NSColor?, cornerRadius: CGFloat?) {
            switch config.backgroundBlur {
            case .macosGlassRegular:
                glass = .regular
            case .macosGlassClear:
                glass = .clear
            default:
                return nil
            }
            self.backgroundColor = preferredBackgroundColor ?? NSColor(config.backgroundColor)
            self.backgroundOpacity = config.backgroundOpacity
            self.cornerRadius = cornerRadius
        }
    }
}
