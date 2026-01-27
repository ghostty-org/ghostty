import AppKit
import SwiftUI

class TerminalWorkspaceViewContainer<ViewModel: TerminalViewModel>: NSView {
    private let contentView: NSView

    private var glassEffectView: NSView?
    private var glassTopConstraint: NSLayoutConstraint?
    private var derivedConfig: DerivedConfig

    init(
        ghostty: Ghostty.App,
        viewModel: ViewModel,
        delegate: (any TerminalViewDelegate)? = nil,
        worktrunkStore: WorktrunkStore,
        worktrunkSidebarState: WorktrunkSidebarState,
        gitDiffSidebarState: GitDiffSidebarState,
        openWorktree: @escaping (String) -> Void,
        resumeSession: ((AISession) -> Void)? = nil,
        onSidebarWidthChange: @escaping (CGFloat) -> Void,
        onGitDiffSelect: @escaping (GitDiffEntry) -> Void,
        onGitDiffWorktreeSelect: @escaping (String?) -> Void
    ) {
        self.derivedConfig = DerivedConfig(config: ghostty.config)
        self.contentView = NSHostingView(rootView: TerminalWorkspaceView(
            ghostty: ghostty,
            viewModel: viewModel,
            delegate: delegate,
            worktrunkStore: worktrunkStore,
            worktrunkSidebarState: worktrunkSidebarState,
            gitDiffSidebarState: gitDiffSidebarState,
            openWorktree: openWorktree,
            resumeSession: resumeSession,
            onSidebarWidthChange: onSidebarWidthChange,
            onGitDiffSelect: onGitDiffSelect,
            onGitDiffWorktreeSelect: onGitDiffWorktreeSelect
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

    override var intrinsicContentSize: NSSize {
        contentView.intrinsicContentSize
    }

    private func setup() {
        addSubview(contentView)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
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

private extension TerminalWorkspaceViewContainer {
#if compiler(>=6.2)
    @available(macOS 26.0, *)
    func addGlassEffectViewIfNeeded() -> NSGlassEffectView? {
        if let existed = glassEffectView as? NSGlassEffectView {
            updateGlassEffectTopInsetIfNeeded()
            return existed
        }
        guard let themeFrameView = window?.contentView?.superview else {
            return nil
        }
        let effectView = NSGlassEffectView()
        addSubview(effectView, positioned: .below, relativeTo: contentView)
        effectView.translatesAutoresizingMaskIntoConstraints = false
        glassTopConstraint = effectView.topAnchor.constraint(
            equalTo: topAnchor,
            constant: -themeFrameView.safeAreaInsets.top
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
#endif

    func updateGlassEffectIfNeeded() {
#if compiler(>=6.2)
        guard #available(macOS 26.0, *), derivedConfig.backgroundBlur.isGlassStyle else {
            glassEffectView?.removeFromSuperview()
            glassEffectView = nil
            glassTopConstraint = nil
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
        // Note: _cornerRadius is private API used to match the window's corner radius for visual
        // consistency. The responds(to:) check ensures we gracefully handle future macOS changes.
        if let window, window.responds(to: Selector(("_cornerRadius"))), let cornerRadius = window.value(forKey: "_cornerRadius") as? CGFloat {
            effectView.cornerRadius = cornerRadius
        }
#endif
    }

    func updateGlassEffectTopInsetIfNeeded() {
#if compiler(>=6.2)
        guard #available(macOS 26.0, *), derivedConfig.backgroundBlur.isGlassStyle else {
            return
        }
        guard glassEffectView != nil else { return }
        guard let themeFrameView = window?.contentView?.superview else { return }
        glassTopConstraint?.constant = -themeFrameView.safeAreaInsets.top
#endif
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
