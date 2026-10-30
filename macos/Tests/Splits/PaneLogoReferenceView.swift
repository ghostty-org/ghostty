import AppKit
import SwiftUI
@testable import Ghostty

// Reference renderer for existing logo-style visual fixtures, not used by the sidebar.
/// Shared by the compact composition and the larger hover inspector.
struct PaneLogoMark: View {
    let pane: SplitTabPane
    let size: CGFloat
    var showsActivity = true

    var body: some View {
            ZStack {
                // The activity tint only applies to an agent logo. A plain
                // terminal or workspace icon has no activity, so the tint would
                // be fully transparent, yet the overlay still moved the icon
                // into a separate hosting view. That view does not carry the
                // icon's foreground style, so a system symbol fell back to its
                // untinted template black.
                Group {
                    if showsActivity && pane.activity != nil {
                        logo
                            .padding(0.5)
                            .frame(width: size, height: size)
                            .modifier(AgentLogoStatus(activity: pane.activity, focused: pane.focused))
                    } else {
                        logo
                            .padding(0.5)
                            .frame(width: size, height: size)
                    }
                }
            }
        .frame(width: size, height: size)
    }

    @ViewBuilder private var logo: some View {
        switch pane.icon {
        case .systemSymbol(let name):
            Image(systemName: name)
                .resizable()
                .scaledToFit()
                .fontWeight(.regular)
                .foregroundStyle(Color.primary.opacity(pane.focused ? 0.95 : 0.65))
        case .asset(let name):
            Image(name).resizable().scaledToFit()
        case .image(let image):
            Image(nsImage: image).resizable().scaledToFit()
        }
    }
}

struct AgentLogoStatus: ViewModifier {
    let activity: TabActivity?
    var focused = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        AgentLogoNativeBreath(
            content: AnyView(content.overlay {
                let tint = activity.flatMap { $0.state == .idle ? nil : $0 }
                    .map { AgentLogoStyle.color($0) } ?? .accentColor
                tint.opacity(AgentLogoStyle.tintStrength(state: activity?.state, focused: focused))
                    .mask(content)
            }),
            working: AgentLogoStyle.animates(state: activity?.state, visible: true, reduceMotion: reduceMotion)
        )
    }
}

/// The animated layer belongs to an AppKit container, not SwiftUI's display
/// list. Its static hosting view has no frame clock or repeating transaction.
struct AgentLogoNativeBreath: NSViewRepresentable {
    let content: AnyView
    let working: Bool

    func makeNSView(context: Context) -> AgentLogoAnimationHost { AgentLogoAnimationHost() }

    func updateNSView(_ view: AgentLogoAnimationHost, context: Context) {
        view.setContent(AnyView(content.environment(\.self, context.environment)), working: working)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AgentLogoAnimationHost, context: Context) -> CGSize? {
        nsView.hostingView.fittingSize
    }

    static func dismantleNSView(_ view: AgentLogoAnimationHost, coordinator: Void) {
        view.stop()
    }
}

@MainActor
final class AgentLogoAnimationHost: NSView {
    let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private var working = false
    private var windowObservers: [NSObjectProtocol] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
    }

    // Icons must not intercept the enclosing tab's clicks or drag initiation.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setContent(_ content: AnyView, working: Bool) {
        hostingView.rootView = content
        self.working = working
        refreshAnimation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeWindowObservers()
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshAnimation() }
                })
            }
        }
        refreshAnimation()
    }

    override func viewDidHide() { super.viewDidHide(); refreshAnimation() }
    override func viewDidUnhide() { super.viewDidUnhide(); refreshAnimation() }

    private func refreshAnimation() {
        let visible = window.map {
            $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        } ?? false
        guard let layer else { return }
        AgentLogoLayerBreath.setRunning(working && visible && !isHiddenOrHasHiddenAncestor, on: layer)
    }

    func stop() {
        working = false
        if let layer { AgentLogoLayerBreath.setRunning(false, on: layer) }
        removeWindowObservers()
    }

    private func removeWindowObservers() {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers.removeAll()
    }
}

